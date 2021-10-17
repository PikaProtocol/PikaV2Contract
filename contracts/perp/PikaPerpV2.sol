// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../oracle/IOracle.sol";
import './IPikaPerp.sol';
import "hardhat/console.sol";

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
        uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
        uint16 minTradeDuration; // In seconds. 2 bytes
        uint16 liquidationThreshold; // In bps. 8000 = 80%. 2 bytes
        uint16 liquidationBounty; // In bps. 500 = 5%. 2 bytes
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
    address public usdc;
    address public oracle;
    address public protocol;
    uint256 public MIN_MARGIN = 1000000000; // 10 usdc
    uint256 public BASE = 1e8;
    uint256 public nextStakeId; // Incremental
    uint256 public nextPositionId; // Incremental
    uint256 public protocolRewardRatio = 3000;  // In bps. 100 = 1%
    uint256 public maxShift = 0.003e8; // max shift (shift is used adjust the price to balance the longs and shorts)
    uint256 minPriceChange = 100; // 1%, the minimum oracle price up change for trader to close trade with profit
    uint256 minProfitTime = 12 hours; // the time window where minProfit is effective
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
    event NewPositionSettled(
        uint256 indexed positionId,
        address indexed user,
        uint256 price
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
        uint256 protocolReward
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
    event FeeUpdated(
        uint256 protocolReward
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

        uint256 shares = vault.staked > 0 ? amount * vault.shares / vault.balance : amount;
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
            uint256 timeDiff = block.timestamp - uint256(_stake.timestamp);
            require(
                (timeDiff > uint256(vault.stakingPeriod)) &&
                (timeDiff % uint256(vault.stakingPeriod)) < uint256(vault.redemptionPeriod)
            , "!period");
        }

        uint256 shareBalance = shares * uint256(vault.balance) / uint256(vault.shares);
        uint256 amount = shares * _stake.amount / uint256(_stake.shares);

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
    ) external {

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), margin / 10**2);

        console.log("transfer in", margin);
        // Check params
        require(margin >= MIN_MARGIN, "!margin");
        require(leverage >= 1 * 10**8, "!leverage");

        // Check product
        Product storage product = products[productId];
        require(product.isActive, "!product-active");
        require(leverage <= uint256(product.maxLeverage), "!max-leverage");

        // Check exposure
        uint256 amount = margin * leverage / 10**8;
        uint256 price = _calculatePriceWithFee(product.feed, uint256(product.fee), isLong, product.openInterestLong,
            product.openInterestShort, uint256(product.maxExposure), uint256(product.reserve), amount);

        if (isLong) {
            product.openInterestLong += uint64(amount);
            require(uint256(product.openInterestLong) <= uint256(product.maxExposure) + uint256(product.openInterestShort), "!exposure-long");
        } else {
            product.openInterestShort += uint64(amount);
            require(uint256(product.openInterestShort) <= uint256(product.maxExposure) + uint256(product.openInterestLong), "!exposure-short");
        }

        address user = msg.sender;
        uint256 positionId = getPositionId(user, productId, isLong);
        Position storage position = positions[positionId];

        if (position.margin > 0) {
            price = (uint256(position.margin).mul(position.leverage).mul(uint256(position.price)).add(margin.mul(leverage).mul(price))).div(
                uint256(position.margin).mul(position.leverage).add(margin.mul(leverage)));
            leverage = (uint256(position.margin).mul(uint256(position.leverage)).add(margin * leverage)).div(uint256(position.margin).add(margin));
            margin = uint256(position.margin).add(margin);
        }

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
        uint256 newMargin = uint256(position.margin) + margin;
        uint256 newLeverage = uint256(position.leverage) * uint256(position.margin) / newMargin;
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

    // Closes margin from Position with id = positionId
    function closePosition(
        uint256 positionId,
        uint256 margin
    ) external {
        // Check params
        require(margin >= MIN_MARGIN, "!margin");

        // Check position
        Position storage position = positions[positionId];
        require(msg.sender == position.owner, "!owner");

        // Check product
        Product storage product = products[uint256(position.productId)];
        require(block.timestamp >= uint256(position.timestamp) + uint256(product.minTradeDuration), "!duration");

        bool isFullClose;
        if (margin >= uint256(position.margin)) {
            margin = uint256(position.margin);
            isFullClose = true;
        }

        uint256 price = _calculatePriceWithFee(product.feed, uint256(product.fee), !position.isLong, product.openInterestLong, product.openInterestShort,
            uint256(product.maxExposure), uint256(product.reserve), margin * position.leverage / 10**8);

        bool isLiquidatable;
        (uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, product.interest);
        if (pnlIsNegative && pnl >= uint256(position.margin) * uint256(product.liquidationThreshold) / 10**4) {
            margin = uint256(position.margin);
            pnl = uint256(position.margin);
            isFullClose = true;
            isLiquidatable = true;
        } else {
            // front running protection: if oracle price up change is smaller than threshold and minProfitTime has not passed, the pnl is be set to 0
            if (!pnlIsNegative && block.timestamp < position.timestamp + minProfitTime && position.oraclePrice * (1e8 + minPriceChange) / 1e8 <= IOracle(oracle).getPrice(product.feed)) {
                pnl = 0;
            }
        }

//        if (releaseMargin && !pnlIsNegative) {
//            pnl = 0;
//        }

        _checkAndUpdateVault(pnl, pnlIsNegative, margin, position.owner);

        if (position.isLong) {
            if (uint256(product.openInterestLong) >= margin * uint256(position.leverage) / 10**8) {
                product.openInterestLong -= uint64(margin * uint256(position.leverage) / 10**8);
            } else {
                product.openInterestLong = 0;
            }
        } else {
            if (uint256(product.openInterestShort) >= margin * uint256(position.leverage) / 10**8) {
                product.openInterestShort -= uint64(margin * uint256(position.leverage) / 10**8);
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

    function _checkAndUpdateVault(uint256 pnl, bool pnlIsNegative, uint256 margin, address positionOwner) internal {
        // Checkpoint vault
        if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
            vault.lastCheckpointTime = uint80(block.timestamp);
            vault.lastCheckpointBalance = uint80(vault.balance);
        }

        // Update vault
        if (pnlIsNegative) {
            if (pnl < margin) {
                console.log("transfer out in loss", margin - pnl);
                console.log("+vault balance pnl", pnl);
                IERC20(usdc).safeTransfer(positionOwner, (margin - pnl) / 10**2);
                vault.balance += uint96(pnl);
            } else {
                vault.balance += uint96(margin);
                console.log("+vault balance margin", margin);
            }

        } else {

            // Check vault
            require(uint256(vault.balance) >= pnl, "!vault-insufficient");
            require(
                uint256(vault.balance) - pnl >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4
            , "!max-drawdown");

            vault.balance -= uint96(pnl);
            console.log("transfer out in profit", margin + pnl);
            console.log("-vault balance", pnl);
            IERC20(usdc).safeTransfer(positionOwner, (margin + pnl) / 10**2);
        }
    }

    function releaseMargin(uint256 positionId) external onlyOwner {

        Position storage position = positions[positionId];
        require(position.margin > 0, "!position");

        Product storage product = products[position.productId];

        uint256 margin = position.margin;
        address positionOwner = position.owner;

        uint256 amount = margin * uint256(position.leverage) / 10**8;
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

        IERC20(usdc).safeTransfer(positionOwner, margin / 10**2);
    }

    function getPositionId(
        address account,
        uint256 productId,
        bool isLong
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(account, productId, isLong)));
    }

    // Liquidate positionIds
    function liquidatePositions(uint256[] calldata positionIds) external {

        require(msg.sender == owner || allowPublicLiquidator, "!liquidator");
        uint256 totalLiquidatorReward;
        uint256 totalProtocolReward;

        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            (uint256 liquidatorReward, uint256 protocolReward) = liquidatePosition(positionId);
            totalLiquidatorReward += liquidatorReward;
            totalProtocolReward += protocolReward;
        }

        if (totalLiquidatorReward > 0) {
            console.log("transfering out totalLiquidatorReward", totalLiquidatorReward / 10**2);
            IERC20(usdc).safeTransfer(msg.sender, totalLiquidatorReward / 10**2);
        }

        if (totalProtocolReward > 0) {
            console.log("transfering out totalProtocolReward", totalProtocolReward / 10**2);
            IERC20(usdc).safeTransfer(protocol, totalProtocolReward / 10**2);
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
            (uint256 pnl, bool pnlIsNegative) = _getPnL(position, price, product.interest);
            if (pnlIsNegative && uint256(position.margin) > pnl) {
                liquidatorReward = (uint256(position.margin) - pnl) * uint256(product.liquidationBounty) / 10**4;
                protocolReward = (uint256(position.margin) - pnl) * protocolRewardRatio / 10**4;
                vault.balance += uint96(uint256(position.margin) - liquidatorReward - protocolReward);
                console.log("+vault balance", uint96(uint256(position.margin) - liquidatorReward - protocolReward));
            } else {
                vault.balance += uint96(position.margin);
                console.log("+vault balance", uint96(position.margin));
            }

            uint256 amount = uint256(position.margin) * uint256(position.leverage) / 10**8;

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
                protocolReward
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

    function getPositions(uint256[] calldata positionIds) external view returns(Position[] memory _positions) {
        uint256 length = positionIds.length;
        _positions = new Position[](length);
        for (uint256 i=0; i < length; i++) {
            _positions[i] = positions[positionIds[i]];
        }
        return _positions;
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

    function _calculatePriceWithFee(
        address feed,
        uint256 fee,
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
            uint256 price = oraclePrice.mul(slippage).div(10**8);
            return price.add(price.mul(fee).div(10**4));
        } else {
            uint256 slippage = (reserve.sub(reserve.mul(reserve).div(reserve.add(amount)))).mul(10**8).div(amount);
            slippage = shift >= 0 ? slippage.add(uint256(shift).div(2)) : slippage.sub(uint256(-1 * shift));
            uint256 price = oraclePrice.mul(slippage).div(10**8);
            return price.sub(price.mul(fee).div(10**4));
        }
    }

    function _getPnL(
        Position memory position,
        uint256 price,
        uint256 interest
    ) internal view returns(uint256 pnl, bool pnlIsNegative) {

        if (position.isLong) {
            if (price >= uint256(position.price)) {
                pnl = uint256(position.margin) * uint256(position.leverage) * (price - uint256(position.price)) / (uint256(position.price) * 10**8);
            } else {
                pnl =  uint256(position.margin) * uint256(position.leverage) * (uint256(position.price) - price) / (uint256(position.price) * 10**8);
                pnlIsNegative = true;
            }
        } else {
            if (price > uint256(position.price)) {
                pnl =  uint256(position.margin) * uint256(position.leverage) * (price - uint256(position.price)) / (uint256(position.price) * 10**8);
                pnlIsNegative = true;
            } else {
                pnl =  uint256(position.margin) * uint256(position.leverage) * (uint256(position.price) - price) / (uint256(position.price) * 10**8);
            }
        }

        // Subtract interest from P/L
        if (block.timestamp >= position.timestamp + 900) {

            uint256 _interest =  uint256(position.margin) * uint256(position.leverage) * interest * (block.timestamp - uint256(position.timestamp)) / (10**12 * 360 days);

            if (pnlIsNegative) {
                pnl += _interest;
            } else if (pnl < _interest) {
                pnl = _interest - pnl;
                pnlIsNegative = true;
            } else {
                pnl -= _interest;
            }

        }

        return (pnl, pnlIsNegative);
    }

    function _calculateInterest(uint256 amount, uint256 timestamp, uint256 interest) internal view returns (uint256) {
        if (block.timestamp < timestamp + 900) return 0;
        return amount * interest * (block.timestamp - timestamp) / (10**4 * 360 days);
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
            minTradeDuration: _product.minTradeDuration,
            liquidationThreshold: _product.liquidationThreshold,
            liquidationBounty: _product.liquidationBounty,
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
        product.minTradeDuration = _product.minTradeDuration;
        product.liquidationThreshold = _product.liquidationThreshold;
        product.liquidationBounty = _product.liquidationBounty;

        emit ProductUpdated(productId, product);

    }

    function setProtocolRewardRatio(uint256 _protocolRewardRatio) external onlyOwner {
        require(_protocolRewardRatio <= 10000, "!too-much"); // 1% and 3%
        protocolRewardRatio = _protocolRewardRatio;
        emit FeeUpdated(protocolRewardRatio);
    }

    function setProtocolAddress(address _protocol) external onlyOwner {
        protocol = _protocol;
        emit ProtocolUpdated(protocol);
    }

    function setCanUserStake(bool _canUserStake) external onlyOwner {
        canUserStake = _canUserStake;
    }

    function setAllowPublicLiquidator(bool _allowPublicLiquidator) external onlyOwner {
        allowPublicLiquidator = _allowPublicLiquidator;
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
