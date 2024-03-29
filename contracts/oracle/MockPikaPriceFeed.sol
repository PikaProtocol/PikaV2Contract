pragma solidity ^0.8.0;

import "./IOracle.sol";
import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";

contract MockPikaPriceFeed is Ownable {
    using SafeMath for uint256;

    uint256 public lastUpdatedTime;
    uint256 public lastChainlinkUpdatedTime;
    uint256 public priceDuration;
    mapping (address => uint256) public priceMap;
    mapping (address => address) public feedTokenMap;
    address public keeper;
    bool public isChainlinkOnly = false;
    uint256 public maxPriceDiff = 2e16; // 2%

    event PriceSet(address token, uint256 price);
    event PriceDurationSet(uint256 priceDuration);
    event MaxPriceDiffSet(uint256 maxPriceDiff);
    event KeeperSet(address keeper);
    event IsChainlinkOnlySet(bool isChainlinkOnlySet);

    uint256 public constant MAX_PRICE_DURATION = 30 minutes;
    uint256 public constant PRICE_BASE = 10000;

    constructor() {
        keeper = msg.sender;
        priceDuration = 300; // 5mins
    }

    function getPrice(address feed) external view returns (uint256) {
        (uint256 chainlinkPrice, uint256 chainlinkTimestamp) = getChainlinkPrice(feed);
        console.log(chainlinkTimestamp, lastUpdatedTime);
        console.log("price duration", priceDuration);
        console.log(block.timestamp, lastUpdatedTime.add(priceDuration));
        console.log(block.timestamp > lastUpdatedTime.add(priceDuration));
        if (isChainlinkOnly || (block.timestamp > lastUpdatedTime.add(priceDuration) && chainlinkTimestamp > lastUpdatedTime)) {
            return chainlinkPrice;
        }
        uint256 pikaPrice = priceMap[feedTokenMap[feed]];
        console.log(pikaPrice, chainlinkPrice);
        uint256 priceDiff = pikaPrice > chainlinkPrice ? (pikaPrice.sub(chainlinkPrice)).mul(1e18).div(chainlinkPrice) :
            (chainlinkPrice.sub(pikaPrice)).mul(1e18).div(chainlinkPrice);
        console.log("priceDiff", priceDiff);
        if (priceDiff > maxPriceDiff) {
            return chainlinkPrice;
        }
        return pikaPrice;
    }

    function getChainlinkPrice(address feed) public view returns (uint256 priceToReturn, uint256 chainlinkTimestamp) {
        require(feed != address(0), '!feed-error');

//        (,int price,,uint timeStamp,) = AggregatorV3Interface(feed).latestRoundData();
        int price = 400000000000;
        uint timeStamp = 1637551983;

        require(price > 0, '!price');
        require(timeStamp > 0, '!timeStamp');
        uint8 decimals = 8;
        chainlinkTimestamp = timeStamp;
        if (decimals != 8) {
            priceToReturn = uint256(price) * (10**8) / (10**uint256(decimals));
        } else {
            priceToReturn = uint256(price);
        }
    }

    function getPrices(address[] memory tokens) external view returns (uint256[] memory){
        uint256[] memory curPrices = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            curPrices[i] = priceMap[tokens[i]];
        }
        return curPrices;
    }

    function setPrices(address[] memory tokens, uint256[] memory prices) external onlyKeeper {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            priceMap[token] = prices[i];
            emit PriceSet(token, prices[i]);
        }
        lastUpdatedTime = block.timestamp;
    }

    function setPriceDuration(uint256 _priceDuration) external onlyOwner {
        require(priceDuration <= MAX_PRICE_DURATION, "!priceDuration");
        priceDuration = _priceDuration;
        emit PriceDurationSet(priceDuration);
    }

    function setTokenForFeed(address[] memory feeds, address[] memory tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            feedTokenMap[feeds[i]] = tokens[i];
        }
    }

    function setMaxPriceDiff(uint256 _maxPriceDiff) external onlyOwner {
        maxPriceDiff = _maxPriceDiff;
        emit MaxPriceDiffSet(maxPriceDiff);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(keeper);
    }

    function setIsChainlinkOnly(bool _isChainlinkOnly) external onlyOwner {
        isChainlinkOnly = _isChainlinkOnly;
        emit IsChainlinkOnlySet(isChainlinkOnly);
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper, "!keeper");
        _;
    }
}
