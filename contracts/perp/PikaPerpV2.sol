// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../oracle/IOracle.sol";
import './IPikaPerp.sol';

contract PikaPerpV2 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // All amounts are stored with 8 decimals

    // Structs

    struct Vault {
        // 32 bytes
        uint96 cap; // Maximum capacity. 12 bytes
        uint96 balance; // 12 bytes
        uint64 staked; // Total staked by users. 8 bytes
        uint64 shares; // Total ownership shares. 8 bytes
        // 32 bytes
        uint80 lastCheckpointBalance; // Used for max drawdown. 10 bytes
        uint80 lastCheckpointTime; // Used for max drawdown. 10 bytes
        uint32 stakingPeriod; // Time required to lock stake (seconds). 4 bytes
        uint32 redemptionPeriod; // Duration for redemptions (seconds). 4 bytes
        uint32 maxDailyDrawdown; // In basis points (bps) 1000 = 10%. 4 bytes
    }

    struct Stake {
        // 32 bytes
        address owner; // 20 bytes
        uint64 amount; // 8 bytes
        uint64 shares; // 8 bytes
        uint32 timestamp; // 4 bytes
    }

    struct Product {
        // 32 bytes
        address feed; // Chainlink feed. 20 bytes
        uint72 maxLeverage; // 9 bytes
        uint16 fee; // In bps. 0.5% = 50. 2 bytes
        bool isActive; // 1 byte
        // 32 bytes
        uint64 maxExposure; // Maximum allowed long/short imbalance. 8 bytes
        uint64 openInterestLong; // 6 bytes
        uint64 openInterestShort; // 6 bytes
        uint16 interest; // For 360 days, in bps. 10% = 1000. 2 bytes
        uint16 liquidationThreshold; // In bps. 8000 = 80%. 2 bytes
        uint16 liquidationBounty; // In bps. 500 = 5%. 2 bytes
        uint16 minPriceChange; // 1.5%, the minimum oracle price up change for trader to close trade with profit
        uint64 reserve; // Virtual reserve in USDC. Used to calculate slippage
    }

    struct Position {
        // 32 bytes
        uint64 productId; // 8 bytes
        uint64 leverage; // 8 bytes
        uint64 price; // 8 bytes
        uint64 oraclePrice; // 8 bytes
        uint64 margin; // 8 bytes
        // 32 bytes
        address owner; // 20 bytes
        uint80 timestamp; // 10 bytes
        bool isLong; // 1 byte
    }

    // Variables

    address public owner; // Contract owner
    address public liquidator;
    address public usdc;
    address public oracle;
    address public protocol;
    uint256 public MIN_MARGIN = 5000000000; // 50 usdc
    uint256 public nextStakeId; // Incremental
    uint256 public protocolRewardRatio = 3000;  // In bps. 100 = 1%
    uint256 public maxShift = 0.003e8; // max shift (shift is used adjust the price to balance the longs and shorts)
    uint256 minProfitTime = 12 hours; // the time window where minProfit is effective
    uint256 maxPositionMargin; // for guarded launch
    bool canUserStake = false;
    bool allowPublicLiquidator = false;
    Vault private vault;

    mapping(uint256 => Product) private products;
    mapping(uint256 => Stake) private stakes;
    mapping(uint256 => Position) private positions;

    // Events

    event Staked(
        uint256 stakeId,
        address indexed user,
        uint256 amount,
        uint256 shares
    );
    event Redeemed(
        uint256 stakeId,
        address indexed user,
        uint256 amount,
        uint256 shares,
        uint256 shareBalance,
        bool isFullRedeem
    );
    event NewPosition(
        uint256 indexed positionId,
        address indexed user,
        uint256 indexed productId,
        bool isLong,
        uint256 price,
        uint256 oraclePrice,
        uint256 margin,
        uint256 leverage
    );

    event AddMargin(
        uint256 indexed positionId,
        address indexed user,
        uint256 margin,
        uint256 newMargin,
        uint256 newLeverage
    );
    event ClosePosition(
        uint256 positionId,
        address indexed user,
        uint256 indexed productId,
        bool indexed isFullClose,
        uint256 price,
        uint256 entryPrice,
        uint256 margin,
        uint256 leverage,
        uint256 pnl,
        bool pnlIsNegative,
        bool wasLiquidated
    );
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 liquidatorReward,
        uint256 protocolReward,
        uint256 vaultReward
    );
    event VaultUpdated(
        Vault vault
    );
    event ProductAdded(
        uint256 productId,
        Product product
    );
    event ProductUpdated(
        uint256 productId,
        Product product
    );
    event ProtocolFeeUpdated(
        uint256 protocolRewardRatio
    );
    event ProtocolUpdated(
        address protocol
    );
    event OwnerUpdated(
        address newOwner
    );

    // Constructor

    constructor(address _usdc, address _oracle) {
        owner = msg.sender;
        liquidator = msg.sender;
        usdc = _usdc;
        oracle = _oracle;
        protocol = msg.sender;
        vault = Vault({
            cap: 0,
            maxDailyDrawdown: 0,
            balance: 0,
            staked: 0,
            shares: 0,
            lastCheckpointBalance: 0,
            lastCheckpointTime: uint80(block.timestamp),
            stakingPeriod: uint32(30 * 24 * 3600),
            redemptionPeriod: uint32(8 * 3600)
        });
    }

    // Methods

    // Stakes amount of usdc in the vault
    function stake(uint256 amount) external {
        require(canUserStake || msg.sender == owner, "!stake");
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount/10**2);
        require(amount >= MIN_MARGIN, "!margin");
        require(uint256(vault.staked) + amount <= uint256(vault.cap), "!cap");

        uint256 shares = vault.staked > 0 ? amount.mul(uint256(vault.shares)).div(uint256(vault.balance)) : amount;
        vault.balance += uint96(amount);
        vault.staked += uint64(amount);
        vault.shares += uint64(shares);
        address user = msg.sender;

        nextStakeId++;
        stakes[nextStakeId] = Stake({
            owner: user,
            amount: uint64(amount),
            shares: uint64(shares),
            timestamp: uint32(block.timestamp)
        });

        emit Staked(
            nextStakeId,
            user,
            amount,
            shares
        );

    }

    // Redeems amount from Stake with id = stakeId
    function redeem(
        uint256 stakeId,
        uint256 shares
    ) external {

        require(shares <= uint256(vault.shares), "!staked");

        address user = msg.sender;

        Stake storage _stake = stakes[stakeId];
        require(_stake.owner == user, "!owner");

        bool isFullRedeem = shares >= uint256(_stake.shares);
        if (isFullRedeem) {
            shares = uint256(_stake.shares);
        }

        if (user != owner) {
            uint256 timeDiff = block.timestamp.sub(uint256(_stake.timestamp));
            require(
                (timeDiff > uint256(vault.stakingPeriod)) &&
                (timeDiff % uint256(vault.stakingPeriod)) < uint256(vault.redemptionPeriod)
            , "!period");
        }

        uint256 shareBalance = shares.mul(uint256(vault.balance)).div(uint256(vault.shares));
        uint256 amount = shares.mul(_stake.amount).div(uint256(_stake.shares));

        _stake.amount -= uint64(amount);
        _stake.shares -= uint64(shares);
        vault.staked -= uint64(amount);
        vault.shares -= uint64(shares);
        vault.balance -= uint96(shareBalance);

        if (isFullRedeem) {
            delete stakes[stakeId];
        }
        IERC20(usdc).safeTransfer(user, shareBalance / 10**2);

        emit Redeemed(
            stakeId,
            user,
            amount,
            shares,
            shareBalance,
            isFullRedeem
        );

    }

    // Opens position with margin = msg.value
    function openPosition(
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 leverage
    ) external returns(uint256 positionId) {
        // Check params
        require(margin >= MIN_MARGIN, "!margin");
        require(leverage >= 1 * 10**8, "!leverage");

        // Check product
        Product storage product = products[productId];
        require(product.isActive, "!product-active");
        require(leverage <= uint256(product.maxLeverage), "!max-leverage");

        // Transfer margin plus fee
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), (margin.add(_getTradeFee(margin, leverage, uint256(product.fee)))).div(10**2));
        vault.balance += uint96(_getTradeFee(margin, leverage, uint256(product.fee)));

        // Check exposure
        uint256 amount = margin.mul(leverage).div(10**8);
        uint256 price = _calculatePrice(product.feed, isLong, product.openInterestLong,
            product.openInterestShort, uint256(product.maxExposure), uint256(product.reserve), amount);

        if (isLong) {
            product.openInterestLong += uint64(amount);
            require(uint256(product.openInterestLong) <= uint256(product.maxExposure).add(uint256(product.openInterestShort)), "!exposure-long");
        } else {
            product.openInterestShort += uint64(amount);
            require(uint256(product.openInterestShort) <= uint256(product.maxExposure).add(uint256(product.openInterestLong)), "!exposure-short");
        }

        address user = msg.sender;
        positionId = getPositionId(user, productId, isLong);
        Position storage position = positions[positionId];
        if (position.margin > 0) {
            price = (uint256(position.margin).mul(position.leverage).mul(uint256(position.price)).add(margin.mul(leverage).mul(price))).div(
                uint256(position.margin).mul(position.leverage).add(margin.mul(leverage)));
            leverage = (uint256(position.margin).mul(uint256(position.leverage)).add(margin * leverage)).div(uint256(position.margin).add(margin));
            margin = uint256(position.margin).add(margin);
        }
        require(margin < maxPositionMargin, "!max margin");

        positions[positionId] = Position({
            owner: user,
            productId: uint64(productId),
            margin: uint64(margin),
            leverage: uint64(leverage),
            price: uint64(price),
            oraclePrice: uint64(IOracle(oracle).getPrice(product.feed)),
            timestamp: uint80(block.timestamp),
            isLong: isLong
        });
        emit NewPosition(
            positionId,
            user,
            productId,
            isLong,
            price,
            IOracle(oracle).getPrice(product.feed),
            margin,
            leverage
        );
    }

    // Add margin to Position with positionId
    function addMargin(uint256 positionId, uint256 margin) external {

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), margin / 10**2);

        // Check params
        require(margin >= MIN_MARGIN, "!margin");

        // Check position
        Position storage position = positions[positionId];
        require(msg.sender == position.owner, "!owner");

        // New position params
        uint256 newMargin = uint256(position.margin).add(margin);
        uint256 newLeverage = uint256(position.leverage).mul(uint256(position.margin)).div(newMargin);
        require(newLeverage >= 1 * 10**8, "!low-leverage");

        position.margin = uint64(newMargin);
        position.leverage = uint64(newLeverage);

        emit AddMargin(
            positionId,
            position.owner,
            margin,
            newMargin,
            newLeverage
        );

    }

    // Closes margin from Position with productId and direction
    function closePosition(
        uint256 productId,
        uint256 margin,
        bool isLong
    ) external {
        return closePositionWithId(getPositionId(msg.sender, productId, isLong), margin);
    }

    // Closes position from Position with id = positionId
    function closePositionWithId(
        uint256 positionId,
        uint256 margin
    ) public {
        // Check params
        require(margin >= MIN_MARGIN, "!margin");

        // Check position
        Position storage position = positions[positionId];
        require(msg.sender == position.owner, "!owner");

        // Check product
        Product storage product = products[uint256(position.productId)];

        bool isFullClose;
        if (margin >= uint256(position.margin)) {
            margin = uint256(position.margin);
            isFullClose = true;
        }

        uint256 price = _calculatePrice(product.feed, !position.isLong, product.openInterestLong, product.openInterestShort,
            uint256(product.maxExposure), uint256(product.reserve), margin * position.leverage / 10**8);

        bool isLiquidatable;
        (uint256 pnl, bool pnlIsNegative) = _getPnl(position, margin, price);
        if (pnlIsNegative && pnl >= uint256(position.margin).mul(uint256(product.liquidationThreshold)).div(10**4)) {
            margin = uint256(position.margin);
            pnl = uint256(position.margin);
            isFullClose = true;
            isLiquidatable = true;
        } else {
            // front running protection: if oracle price up change is smaller than threshold and minProfitTime has not passed, the pnl is be set to 0
            if (!pnlIsNegative && !_canTakeProfit(position, IOracle(oracle).getPrice(product.feed), product.minPriceChange)) {
                pnl = 0;
            }
        }

        _checkAndUpdateVault(pnl, pnlIsNegative, position, uint256(product.fee), uint256(product.interest));

        if (position.isLong) {
            if (uint256(product.openInterestLong) >= margin.mul(uint256(position.leverage)).div(10**8)) {
                product.openInterestLong -= uint64(margin.mul(uint256(position.leverage)).div(10**8));
            } else {
                product.openInterestLong = 0;
            }
        } else {
            if (uint256(product.openInterestShort) >= margin.mul(uint256(position.leverage)).div(10**8)) {
                product.openInterestShort -= uint64(margin.mul(uint256(position.leverage)).div(10**8));
            } else {
                product.openInterestShort = 0;
            }
        }

        emit ClosePosition(
            positionId,
            position.owner,
            uint256(position.productId),
            isFullClose,
            price,
            uint256(position.price),
            margin,
            uint256(position.leverage),
            pnl,
            pnlIsNegative,
            isLiquidatable
        );

        if (isFullClose) {
            delete positions[positionId];
        } else {
            position.margin -= uint64(margin);
        }
    }

    function _checkAndUpdateVault(
        uint256 pnl,
        bool pnlIsNegative,
        Position memory position,
        uint256 fee,
        uint256 interest
    ) internal {
        // Checkpoint vault
        if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
            vault.lastCheckpointTime = uint80(block.timestamp);
            vault.lastCheckpointBalance = uint80(vault.balance);
        }

        (pnl, pnlIsNegative) = _getPnlWithFee(pnl, pnlIsNegative, position, fee, interest);
        bool shouldPayProtocolInterest = true;
        // Update vault
        if (pnlIsNegative) {
            if (pnl < uint256(position.margin)) {
                IERC20(usdc).safeTransfer(position.owner, (uint256(position.margin).sub(pnl)).div(10**2));
                vault.balance += uint96(pnl);
            } else {
                vault.balance += uint96(position.margin);
                shouldPayProtocolInterest = false;
            }

        } else {

            // Check vault
            require(uint256(vault.balance) >= pnl, "!vault-insufficient");
            require(
                uint256(vault.balance) - pnl >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4
            , "!max-drawdown");

            vault.balance -= uint96(pnl);
            IERC20(usdc).safeTransfer(position.owner, (uint256(position.margin).add(pnl)).div(10**2));
        }
        // If user margin is not enough to pay interest, protocol will not receive interest from vault.
        if (shouldPayProtocolInterest) {
            uint256 protocolInterest = _getInterest(position, interest).mul(protocolRewardRatio).div(10**4);
            vault.balance -= uint96(protocolInterest);
            IERC20(usdc).safeTransfer(protocol, protocolInterest.div(10**2));
        }
    }

    function releaseMargin(uint256 positionId) external onlyOwner {

        Position storage position = positions[positionId];
        require(position.margin > 0, "!position");

        Product storage product = products[position.productId];

        uint256 margin = position.margin;
        address positionOwner = position.owner;

        uint256 amount = margin.mul(uint256(position.leverage)).div(10**8);
        // Set exposure
        if (position.isLong) {
            if (product.openInterestLong >= amount) {
                product.openInterestLong -= uint64(amount);
            } else {
                product.openInterestLong = 0;
            }
        } else {
            if (product.openInterestShort >= amount) {
                product.openInterestShort -= uint64(amount);
            } else {
                product.openInterestShort = 0;
            }
        }

        emit ClosePosition(
            positionId,
            positionOwner,
            position.productId,
            true,
            position.price,
            position.price,
            margin,
            position.leverage,
            0,
            false,
            false
        );

        delete positions[positionId];

        IERC20(usdc).safeTransfer(positionOwner, margin.div(10**2));
    }


    // Liquidate positionIds
    function liquidatePositions(uint256[] calldata positionIds) external {

        require(msg.sender == liquidator || allowPublicLiquidator, "!liquidator");
        uint256 totalLiquidatorReward;
        uint256 totalProtocolReward;

        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            (uint256 liquidatorReward, uint256 protocolReward) = liquidatePosition(positionId);
            totalLiquidatorReward = totalLiquidatorReward.add(liquidatorReward);
            totalProtocolReward = totalProtocolReward.add(protocolReward);
        }

        if (totalLiquidatorReward > 0) {
            IERC20(usdc).safeTransfer(msg.sender, totalLiquidatorReward.div(10**2));
        }

        if (totalProtocolReward > 0) {
            IERC20(usdc).safeTransfer(protocol, totalProtocolReward.div(10**2));
        }
    }

    function liquidatePosition(uint256 positionId) public returns(uint256 liquidatorReward, uint256 protocolReward) {
        Position memory position = positions[positionId];

        if (position.productId == 0) {
            return (0, 0);
        }

        Product storage product = products[uint256(position.productId)];
        uint256 price = IOracle(oracle).getPrice(product.feed); // use oracle price for liquidation

        if (_checkLiquidation(position, price, uint256(product.liquidationThreshold))) {
            uint256 vaultReward;
            (uint256 pnl, bool pnlIsNegative) = _getPnl(position, position.margin, price);
            if (pnlIsNegative && uint256(position.margin) > pnl) {
                liquidatorReward = (uint256(position.margin).sub(pnl)).mul(uint256(product.liquidationBounty)).div(10**4);
                protocolReward = (uint256(position.margin).sub(pnl)).mul(protocolRewardRatio).div(10**4);
                vaultReward = uint256(position.margin).sub(liquidatorReward).sub(protocolReward);
                vault.balance += uint96(vaultReward);
            } else {
                vaultReward = position.margin;
                vault.balance += uint96(vaultReward);
            }

            uint256 amount = uint256(position.margin).mul(uint256(position.leverage)).div(10**8);

            if (position.isLong) {
                if (uint256(product.openInterestLong) >= amount) {
                    product.openInterestLong -= uint64(amount);
                } else {
                    product.openInterestLong = 0;
                }
            } else {
                if (uint256(product.openInterestShort) >= amount) {
                    product.openInterestShort -= uint64(amount);
                } else {
                    product.openInterestShort = 0;
                }
            }

            emit ClosePosition(
                positionId,
                position.owner,
                uint256(position.productId),
                true,
                price,
                uint256(position.price),
                uint256(position.margin),
                uint256(position.leverage),
                uint256(position.margin),
                true,
                true
            );

            delete positions[positionId];

            emit PositionLiquidated(
                positionId,
                msg.sender,
                liquidatorReward,
                protocolReward,
                vaultReward
            );
        }
        return (liquidatorReward, protocolReward);
    }

    // Getters

    function getVault() external view returns(Vault memory) {
        return vault;
    }

    function getProduct(uint256 productId) external view returns(Product memory) {
        return products[productId];
    }

    function getPositionId(
        address account,
        uint256 productId,
        bool isLong
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(account, productId, isLong)));
    }

    function getPosition(
        address account,
        uint256 productId,
        bool isLong
    ) external view returns(Position memory position) {
        position = positions[getPositionId(account, productId, isLong)];
    }

    function getPositions(uint256[] calldata positionIds) external view returns(Position[] memory _positions) {
        uint256 length = positionIds.length;
        _positions = new Position[](length);
        for (uint256 i=0; i < length; i++) {
            _positions[i] = positions[positionIds[i]];
        }
    }

    function getStakes(uint256[] calldata stakeIds) external view returns(Stake[] memory _stakes) {
        uint256 length = stakeIds.length;
        _stakes = new Stake[](length);
        for (uint256 i=0; i < length; i++) {
            _stakes[i] = stakes[stakeIds[i]];
        }
        return _stakes;
    }

    // Internal methods

    function _canTakeProfit(
        Position memory position,
        uint256 oraclePrice,
        uint256 minPriceChange
    ) internal view returns(bool) {
        if (block.timestamp > uint256(position.timestamp).add(minProfitTime)) {
            return true;
        } else if (position.isLong && oraclePrice > uint256(position.oraclePrice).mul(uint256(1e4).add(minPriceChange)).div(1e4)) {
            return true;
        } else if (!position.isLong && oraclePrice < uint256(position.oraclePrice).mul(uint256(1e4).sub(minPriceChange)).div(1e4)) {
            return true;
        }
        return false;
    }

    function _calculatePrice(
        address feed,
        bool isLong,
        uint256 openInterestLong,
        uint256 openInterestShort,
        uint256 maxExposure,
        uint256 reserve,
        uint256 amount
    ) internal view returns(uint256) {

        uint256 oraclePrice = IOracle(oracle).getPrice(feed);
        int256 shift = (int256(openInterestLong) - int256(openInterestShort)) * int256(maxShift) / int256(maxExposure);
        if (isLong) {
            uint256 slippage = (reserve.mul(reserve).div(reserve.sub(amount)).sub(reserve)).mul(10**8).div(amount);
            slippage = shift >= 0 ? slippage.add(uint256(shift)) : slippage.sub(uint256(-1 * shift).div(2));
            return oraclePrice.mul(slippage).div(10**8);
        } else {
            uint256 slippage = (reserve.sub(reserve.mul(reserve).div(reserve.add(amount)))).mul(10**8).div(amount);
            slippage = shift >= 0 ? slippage.add(uint256(shift).div(2)) : slippage.sub(uint256(-1 * shift));
            return oraclePrice.mul(slippage).div(10**8);
        }
    }

    function _getInterest(
        Position memory position,
        uint256 interest
    ) internal view returns(uint256) {
        return uint256(position.margin).mul(uint256(position.leverage)).mul(interest)
            .mul(block.timestamp.sub(uint256(position.timestamp))).div(uint256(10**12).mul(360 days));
    }

    function _getPnl(
        Position memory position,
        uint256 margin,
        uint256 price
    ) internal pure returns(uint256 pnl, bool pnlIsNegative) {
        if (position.isLong) {
            if (price >= uint256(position.price)) {
                pnl = margin.mul(uint256(position.leverage)).mul(price.sub(uint256(position.price))).div(uint256(position.price)).div(10**8);
            } else {
                pnl = margin.mul(uint256(position.leverage)).mul(uint256(position.price).sub(price)).div(uint256(position.price)).div(10**8);
                pnlIsNegative = true;
            }
        } else {
            if (price > uint256(position.price)) {
                pnl = margin.mul(uint256(position.leverage)).mul(price - uint256(position.price)).div(uint256(position.price)).div(10**8);
                pnlIsNegative = true;
            } else {
                pnl = margin.mul(uint256(position.leverage)).mul(uint256(position.price).sub(price)).div(uint256(position.price)).div(10**8);
            }
        }
        return (pnl, pnlIsNegative);
    }

    function _getPnlWithFee(
        uint256 pnl,
        bool pnlIsNegative,
        Position memory position,
        uint256 fee,
        uint256 interest
    ) internal view returns(uint256, bool) {
        // Subtract trade fee from P/L
        uint256 tradeFee = _getTradeFee(uint256(position.margin), uint256(position.leverage), fee);
        if (pnlIsNegative) {
            pnl = pnl.add(tradeFee);
        } else if (pnl < tradeFee) {
            pnl = tradeFee.sub(pnl);
            pnlIsNegative = true;
        } else {
            pnl = pnl.sub(tradeFee);
        }

        // Subtract interest from P/L
        uint256 _interest = _getInterest(position, interest);
        if (pnlIsNegative) {
            pnl = pnl.add(_interest);
        } else if (pnl < _interest) {
            pnl = _interest.sub(pnl);
            pnlIsNegative = true;
        } else {
            pnl = pnl.sub(_interest);
        }
        return (pnl, pnlIsNegative);
    }

    function _getTradeFee(
        uint256 margin,
        uint256 leverage,
        uint256 fee
    ) internal pure returns(uint256) {
        return margin.mul(leverage).div(10**8).mul(fee).div(10**4);
    }

    function _checkLiquidation(
        Position memory position,
        uint256 price,
        uint256 liquidationThreshold
    ) internal pure returns (bool) {

        uint256 liquidationPrice;

        if (position.isLong) {
            liquidationPrice = position.price - position.price * liquidationThreshold * 10**4 / uint256(position.leverage);
        } else {
            liquidationPrice = position.price + position.price * liquidationThreshold * 10**4 / uint256(position.leverage);
        }

        if (position.isLong && price <= liquidationPrice || !position.isLong && price >= liquidationPrice) {
            return true;
        } else {
            return false;
        }
    }

    // Owner methods

    function updateVault(Vault memory _vault) external onlyOwner {
        require(_vault.cap > 0, "!cap");
        require(_vault.maxDailyDrawdown > 0, "!maxDailyDrawdown");
        require(_vault.stakingPeriod > 0, "!stakingPeriod");
        require(_vault.redemptionPeriod > 0, "!redemptionPeriod");

        vault.cap = _vault.cap;
        vault.maxDailyDrawdown = _vault.maxDailyDrawdown;
        vault.stakingPeriod = _vault.stakingPeriod;
        vault.redemptionPeriod = _vault.redemptionPeriod;

        emit VaultUpdated(vault);

    }

    function addProduct(uint256 productId, Product memory _product) external onlyOwner {

        Product memory product = products[productId];
        require(product.maxLeverage == 0, "!product-exists");

        require(_product.maxLeverage > 0, "!max-leverage");
        require(_product.feed != address(0), "!feed");
        require(_product.liquidationThreshold > 0, "!liquidationThreshold");

        products[productId] = Product({
            feed: _product.feed,
            maxLeverage: _product.maxLeverage,
            fee: _product.fee,
            isActive: true,
            maxExposure: _product.maxExposure,
            openInterestLong: 0,
            openInterestShort: 0,
            interest: _product.interest,
            liquidationThreshold: _product.liquidationThreshold,
            liquidationBounty: _product.liquidationBounty,
            minPriceChange: _product.minPriceChange,
            reserve: _product.reserve
        });

        emit ProductAdded(productId, products[productId]);

    }

    function updateProduct(uint256 productId, Product memory _product) external onlyOwner {

        Product storage product = products[productId];
        require(product.maxLeverage > 0, "!product-exists");

        require(_product.maxLeverage >= 1 * 10**8, "!max-leverage");
        require(_product.feed != address(0), "!feed");
        require(_product.liquidationThreshold > 0, "!liquidationThreshold");

        product.feed = _product.feed;
        product.maxLeverage = _product.maxLeverage;
        product.fee = _product.fee;
        product.isActive = _product.isActive;
        product.maxExposure = _product.maxExposure;
        product.interest = _product.interest;
        product.liquidationThreshold = _product.liquidationThreshold;
        product.liquidationBounty = _product.liquidationBounty;

        emit ProductUpdated(productId, product);

    }

    function setProtocolRewardRatio(uint256 _protocolRewardRatio) external onlyOwner {
        require(_protocolRewardRatio <= 10000, "!too-much"); // 1% and 3%
        protocolRewardRatio = _protocolRewardRatio;
        emit ProtocolFeeUpdated(protocolRewardRatio);
    }

    function setProtocolAddress(address _protocol) external onlyOwner {
        protocol = _protocol;
        emit ProtocolUpdated(protocol);
    }

    function setMaxPositionMargin(uint256 _maxPositionMargin) external onlyOwner {
        maxPositionMargin = _maxPositionMargin;
    }

    function setCanUserStake(bool _canUserStake) external onlyOwner {
        canUserStake = _canUserStake;
    }

    function setAllowPublicLiquidator(bool _allowPublicLiquidator) external onlyOwner {
        allowPublicLiquidator = _allowPublicLiquidator;
    }

    function setLiquidator(address _liquidator) external onlyOwner {
        liquidator = _liquidator;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
        emit OwnerUpdated(_owner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

}
