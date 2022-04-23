// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";

contract PikaPriceFeed is Ownable {
    using SafeMath for uint256;

    uint256 public lastUpdatedTime;
    uint256 public priceDuration = 300; // 5mins
    mapping (address => uint256) public priceMap;
    mapping (address => address) public tokenFeedMap;
    mapping(address => bool) public keepers;
    bool public isChainlinkOnly = false;
    uint256 public maxPriceDiff = 2e16; // 2%
    uint256 public delta = 20; // 20bp
    uint256 public decay = 9000; // 0.9

    event PriceSet(address token, uint256 price, uint256 timestamp);
    event PriceDurationSet(uint256 priceDuration);
    event MaxPriceDiffSet(uint256 maxPriceDiff);
    event KeeperSet(address keeper, bool isActive);
    event DeltaAndDecaySet(uint256 delta, uint256 decay);
    event IsChainlinkOnlySet(bool isChainlinkOnlySet);

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;
    uint256 public constant PRICE_BASE = 10000;

    constructor() {
        keepers[msg.sender] = true;
    }

    function getPrice(address token) public view returns (uint256) {
        (uint256 chainlinkPrice, uint256 chainlinkTimestamp) = getChainlinkPrice(token);
        if (isChainlinkOnly || (block.timestamp > lastUpdatedTime.add(priceDuration) && chainlinkTimestamp > lastUpdatedTime)) {
            return chainlinkPrice;
        }
        uint256 pikaPrice = priceMap[token];
        uint256 priceDiff = pikaPrice > chainlinkPrice ? (pikaPrice.sub(chainlinkPrice)).mul(1e18).div(chainlinkPrice) :
            (chainlinkPrice.sub(pikaPrice)).mul(1e18).div(chainlinkPrice);
        if (priceDiff > maxPriceDiff) {
            return chainlinkPrice;
        }
        return pikaPrice;
    }

    function getChainlinkPrice(address token) public view returns (uint256 priceToReturn, uint256 chainlinkTimestamp) {
        address feed = tokenFeedMap[token];
        require(feed != address(0), '!feed-error');

        (,int256 price,,uint256 timeStamp,) = AggregatorV3Interface(feed).latestRoundData();

        require(price > 0, '!price');
        require(timeStamp > 0, '!timeStamp');
        uint8 decimals = AggregatorV3Interface(feed).decimals();
        chainlinkTimestamp = timeStamp;
        if (decimals != 8) {
            priceToReturn = uint256(price) * (10**8) / (10**uint256(decimals));
        } else {
            priceToReturn = uint256(price);
        }
    }

    function getPrices(address[] memory feeds) external view returns (uint256[] memory){
        uint256[] memory curPrices = new uint256[](feeds.length);
        for (uint256 i = 0; i < feeds.length; i++) {
            curPrices[i] = getPrice(feeds[i]);
        }
        return curPrices;
    }

    function getLastNPrices(address token, uint256 n) external view returns(uint256[] memory) {
        address feed = tokenFeedMap[token];
        require(feed != address(0), '!feed-error');

        uint256[] memory prices = new uint256[](n);
        uint8 decimals = AggregatorV3Interface(feed).decimals();
        (uint80 roundId,,,,) = AggregatorV3Interface(feed).latestRoundData();

        for (uint256 i = 0; i < n; i++) {
            (,int256 price,,,) = AggregatorV3Interface(feed).getRoundData(roundId - uint80(i));
            require(price > 0, '!price');
            uint256 priceToReturn;
            if (decimals != 8) {
                priceToReturn = uint256(price) * (10**8) / (10**uint256(decimals));
            } else {
                priceToReturn = uint256(price);
            }
            prices[i] = priceToReturn;
        }
        return prices;
    }

    function setPrices(address[] memory tokens, uint256[] memory prices) external onlyKeeper {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            priceMap[token] = prices[i];
            emit PriceSet(token, prices[i], block.timestamp);
        }
        lastUpdatedTime = block.timestamp;
    }

    function setPriceDuration(uint256 _priceDuration) external onlyOwner {
        require(priceDuration <= MAX_PRICE_DURATION, "!priceDuration");
        priceDuration = _priceDuration;
        emit PriceDurationSet(priceDuration);
    }

    function setFeedForToken(address[] memory feeds, address[] memory tokens) external onlyOwner {
        require(feeds.length == tokens.length, "!length");
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenFeedMap[tokens[i]] = feeds[i];
        }
    }

    function setMaxPriceDiff(uint256 _maxPriceDiff) external onlyOwner {
        maxPriceDiff = _maxPriceDiff;
        emit MaxPriceDiffSet(maxPriceDiff);
    }

    function setKeeper(address _keeper, bool _isActive) external onlyOwner {
        keepers[_keeper] = _isActive;
        emit KeeperSet(_keeper, _isActive);
    }

    function setIsChainlinkOnly(bool _isChainlinkOnly) external onlyOwner {
        isChainlinkOnly = _isChainlinkOnly;
        emit IsChainlinkOnlySet(isChainlinkOnly);
    }

    function setDeltaAndDecay(uint256 _delta, uint256 _decay) external onlyOwner {
        delta = _delta;
        decay = _decay;
        emit DeltaAndDecaySet(delta, decay);
    }

    modifier onlyKeeper() {
        require(keepers[msg.sender], "!keepers");
        _;
    }
}
