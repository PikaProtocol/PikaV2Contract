// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import './IPikaPerp.sol';
import "hardhat/console.sol";

contract PikaPerpV2 {
    using SafeMath for uint256;
    using SafeMath for uint64;
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
        uint48 openInterestLong; // 6 bytes
        uint48 openInterestShort; // 6 bytes
        uint16 interest; // For 360 days, in bps. 5.35% = 535. 2 bytes
        uint16 minTradeDuration; // In seconds. 2 bytes
        uint16 liquidationThreshold; // In bps. 8000 = 80%. 2 bytes
        uint16 liquidationBounty; // In bps. 500 = 5%. 2 bytes
        uint64 reserve; // Virtual reserve in ETH. Used to calculate slippage
    }

    struct Position {
        // 32 bytes
        uint64 productId; // 8 bytes
        uint64 leverage; // 8 bytes
        uint64 price; // 8 bytes
        uint64 margin; // 8 bytes
        // 32 bytes
        address owner; // 20 bytes
        uint80 timestamp; // 10 bytes
        bool isLong; // 1 byte
    }

    // Variables

    address public owner; // Contract owner
    uint256 public MIN_MARGIN = 100000; // 0.001 ETH
    uint256 public BASE = 1e8;
    uint256 public nextStakeId; // Incremental
    uint256 public nextPositionId; // Incremental
    uint256 public protocolFee;  // In bps. 0.01e8 = 1%
    uint256 public maxShift = 0.003e8; // max shift (shift is used adjust the price to balance the longs and shorts)
    uint256 public checkBackRounds = 100; // number of rounds to check back to search for the first round with timestamp that is larger than target timestamp
    uint256 minProfit = 0.01e8; // 1%, the minimum profit percent for trader to close trade with profit
    uint256 minProfitTime = 12 hours; // the time window where minProfit is effective
    uint256 averageMintPikaPrice;
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
        uint256 vaultReward,
        uint256 liquidatorReward
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
        uint256 protocolFee
    );
    event OwnerUpdated(
        address newOwner
    );

    // Constructor

    constructor() {
        owner = msg.sender;
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

    // Stakes msg.value in the vault
    function stake() external payable {

        uint256 amount = msg.value / 10**10; // truncate to 8 decimals

        require(amount >= MIN_MARGIN, "!margin");
        require(uint256(vault.staked) + amount <= uint256(vault.cap), "!cap");

        uint256 shares = vault.staked > 0 ? amount * vault.balance / vault.staked : amount;

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

        uint256 shareBalance = shares * uint256(vault.balance) / uint256(vault.staked);
        uint256 amount = shares * _stake.amount / uint256(_stake.shares);
        console.log(uint256(vault.balance),_stake.amount);

        _stake.amount -= uint64(amount);
        _stake.shares -= uint64(shares);
        vault.staked -= uint64(amount);
        vault.shares -= uint64(shares);
        vault.balance -= uint96(shareBalance);

        if (isFullRedeem) {
            delete stakes[stakeId];
        }
        payable(user).transfer(shareBalance * 10**10);

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
        bool isLong,
        uint256 leverage
    ) external payable {

        uint256 margin = msg.value / 10**10; // truncate to 8 decimals
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
            product.openInterestLong += uint48(amount);
            require(uint256(product.openInterestLong) <= uint256(product.maxExposure) + uint256(product.openInterestShort), "!exposure-long");
        } else {
            product.openInterestShort += uint48(amount);
            require(uint256(product.openInterestShort) <= uint256(product.maxExposure) + uint256(product.openInterestLong), "!exposure-short");
        }

        address user = msg.sender;

        uint256 positionId = getPositionId(user, productId, isLong);

        Position storage position = positions[positionId];


        if (position.margin > 0) {
//            console.log("price", price);
            price = (position.margin.mul(position.leverage).mul(position.price).add(margin.mul(leverage).mul(price))).div
                (position.margin.mul(position.leverage).add(margin.mul(leverage)));
            leverage = (position.margin.mul(position.leverage).add(margin * leverage)).div(position.margin.add(margin));
            margin = position.margin.add(margin);
//            console.log("price", price);
//            console.log("leverage", leverage);
        }

        positions[positionId] = Position({
            owner: user,
            productId: uint64(productId),
            margin: uint64(margin),
            leverage: uint64(leverage),
            price: uint64(price),
            timestamp: uint80(block.timestamp),
            isLong: isLong
        });

        emit NewPosition(
            positionId,
            user,
            productId,
            isLong,
            price,
            margin,
            leverage
        );

    }

    // Add margin = msg.value to Position with id = positionId
    function addMargin(uint256 positionId) external payable {

        uint256 margin = msg.value / 10**10; // truncate to 8 decimals

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
        uint256 margin,
        bool releaseMargin
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


        uint256 pnl;
        bool pnlIsNegative;

        bool isLiquidatable = _checkLiquidation(position, price, uint256(product.liquidationThreshold));

        if (isLiquidatable) {
            margin = uint256(position.margin);
            pnl = uint256(position.margin);
            pnlIsNegative = true;
            isFullClose = true;
        } else {
            if (position.isLong) {
                if (price >= uint256(position.price)) {
                    pnl = margin * uint256(position.leverage) * (price - uint256(position.price)) / (uint256(position.price) * 10**8);
                } else {
                    pnl = margin * uint256(position.leverage) * (uint256(position.price) - price) / (uint256(position.price) * 10**8);
                    pnlIsNegative = true;
                }
            } else {
                if (price > uint256(position.price)) {
                    pnl = margin * uint256(position.leverage) * (price - uint256(position.price)) / (uint256(position.price) * 10**8);
                    pnlIsNegative = true;
                } else {
                    pnl = margin * uint256(position.leverage) * (uint256(position.price) - price) / (uint256(position.price) * 10**8);
                }
            }
//            console.log(pnlIsNegative, margin * uint256(position.leverage) * minProfit / 10**16);
            // front running protection: if pnl is smaller than min profit threshold and minProfitTime has not passed, the pnl is be set to 0
            if (!pnlIsNegative && block.timestamp < position.timestamp + minProfitTime && pnl < margin * uint256(position.leverage) * minProfit / 10**16) {
//                console.log("setting pnl to 0");
                pnl = 0;
            }
//            console.log("pnl", pnl);

            // Subtract interest from P/L
            uint256 interest = _calculateInterest(margin * uint256(position.leverage) / 10**8, uint256(position.timestamp), uint256(product.interest));
//            console.log("interest", interest);
            if (pnlIsNegative) {
                pnl += interest;
            } else if (pnl < interest) {
                pnl = interest - pnl;
                pnlIsNegative = true;
            } else {
                pnl -= interest;
            }

            // Calculate protocol fee
            if (protocolFee > 0) {
                uint256 protocolFeeAmount = protocolFee * margin * position.leverage / 10**16;
//                console.log("protocolFeeAmount", protocolFeeAmount);
                payable(owner).transfer((protocolFeeAmount) * 10**10);
                console.log("transfer out protocol fee", protocolFeeAmount);
                if (pnlIsNegative) {
                    pnl += protocolFeeAmount;
                } else if (pnl < protocolFeeAmount) {
                    pnl = protocolFeeAmount - pnl;
                    pnlIsNegative = true;
                } else {
                    pnl -= protocolFeeAmount;
                }
            }
            console.log(pnlIsNegative, pnl);


        }

        pnl = _checkAndUpdateVault(pnl, pnlIsNegative, margin, releaseMargin, position.owner);

        if (position.isLong) {
            if (uint256(product.openInterestLong) >= margin * uint256(position.leverage) / 10**8) {
                product.openInterestLong -= uint48(margin * uint256(position.leverage) / 10**8);
            } else {
                product.openInterestLong = 0;
            }
        } else {
            if (uint256(product.openInterestShort) >= margin * uint256(position.leverage) / 10**8) {
                product.openInterestShort -= uint48(margin * uint256(position.leverage) / 10**8);
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

    function _checkAndUpdateVault(uint256 pnl, bool pnlIsNegative, uint256 margin, bool releaseMargin, address positionOwner) internal returns(uint256) {
        // Checkpoint vault
        if (uint256(vault.lastCheckpointTime) < block.timestamp - 24 hours) {
            vault.lastCheckpointTime = uint80(block.timestamp);
            vault.lastCheckpointBalance = uint80(vault.balance);
        }

        // Update vault
        if (pnlIsNegative) {
            if (pnl < margin) {
                payable(positionOwner).transfer((margin - pnl) * 10**10);
                console.log("transfer out in loss", margin - pnl);
                console.log("+vault balance pnl", pnl);
                vault.balance += uint96(pnl);
            } else {
                vault.balance += uint96(margin);
                console.log("+vault balance margin", margin);
            }

        } else {

            if (releaseMargin) {
                // When there's not enough funds in the vault, user can choose to receive their margin without profit
                pnl = 0;
            }

            // Check vault
            require(uint256(vault.balance) >= pnl, "!vault-insufficient");
            require(
                uint256(vault.balance) - pnl >= uint256(vault.lastCheckpointBalance) * (10**4 - uint256(vault.maxDailyDrawdown)) / 10**4
            , "!max-drawdown");

            vault.balance -= uint96(pnl);
            console.log("transfer out in profit", margin + pnl);
            console.log("-vault balance", pnl);
            payable(positionOwner).transfer((margin + pnl) * 10**10);

        }
        return pnl;
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

        address liquidator = msg.sender;
        uint256 length = positionIds.length;
        uint256 totalLiquidatorReward;

        for (uint256 i = 0; i < length; i++) {

            uint256 positionId = positionIds[i];
            Position memory position = positions[positionId];

            if (position.productId == 0) {
                continue;
            }

            Product storage product = products[uint256(position.productId)];

            uint256 price = _calculatePriceWithFee(product.feed, uint256(product.fee), !position.isLong, product.openInterestLong, product.openInterestShort,
                uint256(product.maxExposure), uint256(product.reserve), position.margin * position.leverage / 10**8);

            // Local test
            // price = 20000*10**8;

            if (_checkLiquidation(position, price, uint256(product.liquidationThreshold))) {

                uint256 vaultReward = uint256(position.margin) * (10**4 - uint256(product.liquidationBounty)) / 10**4;
                vault.balance += uint96(vaultReward);

                uint256 liquidatorReward = uint256(position.margin) - vaultReward;
                totalLiquidatorReward += liquidatorReward;

                uint256 amount = uint256(position.margin) * uint256(position.leverage) / 10**8;

                if (position.isLong) {
                    if (uint256(product.openInterestLong) >= amount) {
                        product.openInterestLong -= uint48(amount);
                    } else {
                        product.openInterestLong = 0;
                    }
                } else {
                    if (uint256(product.openInterestShort) >= amount) {
                        product.openInterestShort -= uint48(amount);
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
                    liquidator,
                    uint256(vaultReward),
                    uint256(liquidatorReward)
                );

            }

        }

        if (totalLiquidatorReward > 0) {
            payable(liquidator).transfer(totalLiquidatorReward);
        }
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

    function getLatestPrice(
        address feed,
        uint256 productId
    ) public view returns (uint256) {

        // local test
        //return 33500 * 10**8;

        if (productId > 0) { // for client
            Product memory product = products[productId];
            feed = product.feed;
        }

        require(feed != address(0), '!feed-error');

        (
        ,
        int price,
        ,
        uint timeStamp,

        ) = AggregatorV3Interface(feed).latestRoundData();

        require(price > 0, '!price');
        require(timeStamp > 0, '!timeStamp');

        uint8 decimals = AggregatorV3Interface(feed).decimals();

        uint256 priceToReturn;
        if (decimals != 8) {
            priceToReturn = uint256(price) * (10**8) / (10**uint256(decimals));
        } else {
            priceToReturn = uint256(price);
        }

        return priceToReturn;

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

        uint256 oraclePrice = getLatestPrice(feed, 0);
        int256 shift = (int256(openInterestLong) - int256(openInterestShort)) * int256(maxShift) / int256(maxExposure);
        console.log(openInterestLong, openInterestShort);
        if (isLong) {
//            console.log("amount", amount);
            uint256 slippage = ((reserve * reserve / (reserve - amount) - reserve) * (10**8) / amount);
//            console.log("max exposure", maxExposure);
//            console.log("max shift", maxShift);
//            console.log("cal slippage", slippage);
            slippage = shift >= 0 ? slippage + uint256(shift) : slippage - uint256(-1 * shift) / 2;
//            console.log("shift", shift > 0? uint256(shift) : uint256(-1 * shift));
//            console.log("cal slippage", slippage);
            uint256 price = oraclePrice * slippage / (10**8);
            console.log("cal price", price);
//            console.log("price", price + price * fee / 10**4);
            return price + price * fee / 10**4;
        } else {
            uint256 slippage = ((reserve - reserve * reserve / (reserve + amount)) * (10**8) / amount);
            slippage = shift >= 0 ? slippage + uint256(shift) / 2 : slippage - uint256(-1 * shift);
//            console.log("cal slippage", slippage);
            uint256 price = oraclePrice * slippage / (10**8);
            console.log("cal price", price);
            return price - price * fee / 10**4;
        }
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
//        console.log("owner", owner);
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

    function setProtocolFees(uint256 newProtocolFee) external onlyOwner {
        require(newProtocolFee <= 0.03e8, "!too-much"); // 1% and 3%
        protocolFee = newProtocolFee;
        emit FeeUpdated(protocolFee);
    }

    function setCheckBackRounds(uint newCheckBackRounds) external onlyOwner {
        checkBackRounds = newCheckBackRounds;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

}
