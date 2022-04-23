// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../oracle/IOracle.sol";

contract FeeCalculator is Ownable {

    uint256 public constant PRICE_BASE = 10000;
    uint256 public threshold;
    uint256 public weightDecay;
    uint256 public baseFee = 10;
    uint256 public n = 1;
    uint256 public maxDynamicFee = 50; // 0.5%
    address public oracle;


    constructor(uint256 _threshold, uint256 _weightDecay, address _oracle) public {
        threshold = _threshold;
        weightDecay = _weightDecay;
        oracle = _oracle;
    }

    function getFee(address token, address account) external view returns (int256) {
        return getDynamicFee(token);
    }

    /**
     * @notice The dynamic fee to add to base fee. It is updated based on the volatility of recent price updates
     * Larger volatility leads to the higher the dynamic fee. It is used to mitigate oracle front-running.
     */
    function getDynamicFee(address token) public view returns (int256) {
        uint256[] memory prices = IOracle(oracle).getLastNPrices(token, n);
        uint dynamicFee = 0;
        // go backwards in price array
        for (uint i = prices.length - 1; i > 0; i--) {
            dynamicFee = dynamicFee * weightDecay / PRICE_BASE;
            uint deviation = _calDeviation(prices[i - 1], prices[i], threshold);
            dynamicFee += deviation;
        }
        dynamicFee = dynamicFee > maxDynamicFee ? maxDynamicFee : dynamicFee;
        return int256(dynamicFee);
    }

    function _calDeviation(
        uint256 price,
        uint256 previousPrice,
        uint256 threshold
    ) internal pure returns (uint256) {
        if (previousPrice == 0) {
            return 0;
        }
        uint256 absDelta = price > previousPrice ? price - previousPrice : previousPrice - price;
        uint256 deviationRatio = absDelta * PRICE_BASE / previousPrice;
        return deviationRatio > threshold ? deviationRatio - threshold : 0;
    }

    function setThreshold(uint256 _threshold) external onlyOwner {
        threshold = _threshold;
    }

    function setWeightDecay(uint256 _weightDecay) external onlyOwner {
        weightDecay = _weightDecay;
    }

    function setN(uint256 _n) external onlyOwner {
        n = _n;
    }

    function setMaxDynamicFee(uint256 _maxDynamicFee) external onlyOwner {
        maxDynamicFee = _maxDynamicFee;
    }

}
