// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../oracle/IOracle.sol";

contract FeeCalculator is Ownable {

    uint256 public constant PRICE_BASE = 10000;
    address public protocolToken;
    uint256 public threshold;
    uint256 public weightDecay;
    uint256 public baseFee = 10;
    uint256 public n = 1;
    address public oracle;
    // [1000, 10000, 100000, 500000, 1000000, 2500000, 5000000]
    uint256[] public tokenTiers;
    // [0%,   5%,     15%,   25%,    35%,     40%,     45%,     50%    ]
    uint256[] public discounts;

    constructor(address _protocolToken, uint256 _threshold, uint256 _weightDecay, address _oracle) public {
        protocolToken = _protocolToken;
        threshold = _threshold;
        weightDecay = _weightDecay;
        oracle = _oracle;
    }

    function getFee(address token, address account) external view returns (int256) {
        return getDynamicFee(token) - getFeeDiscount(account) * int256(baseFee) / int256(PRICE_BASE);
    }

    function getDynamicFee(address token) public view returns (int256) {
        uint256[] memory prices = IOracle(oracle).getLastNPrices(token, n);
        uint dynamicFee = 0;
        // go backwards in price array
        for (uint i = prices.length - 1; i > 0; i--) {
            dynamicFee = dynamicFee * weightDecay / PRICE_BASE;
            uint deviation = _calDeviation(prices[i - 1], prices[i], threshold);
            dynamicFee += deviation;
        }
        return int256(dynamicFee);
    }

    function _calDeviation(
        uint price,
        uint previousPrice,
        uint threshold
    ) internal pure returns (uint) {
        if (previousPrice == 0) {
            return 0;
        }
        uint absDelta = price > previousPrice ? price - previousPrice : previousPrice - price;
        uint deviationRatio = absDelta * PRICE_BASE / previousPrice;
        return deviationRatio > threshold ? deviationRatio - threshold : 0;
    }

    function getFeeDiscount(address account) public view returns(int256) {
        uint256 tokenBalance = IERC20(protocolToken).balanceOf(account);
        if (tokenBalance == 0) {
            return 0;
        }
        for (uint i = 0; i < tokenTiers.length; i++) {
            if (tokenBalance < tokenTiers[i]) {
                return int256(discounts[i]);
            }
        }
        return int256(discounts[discounts.length - 1]);
    }

    function setFeeTier(uint256[] memory _tokenTiers, uint256[] memory _discounts) external onlyOwner {
        require(_tokenTiers.length + 1 == _discounts.length, "!length");
        tokenTiers = _tokenTiers;
        discounts = _discounts;
    }

    function setThreshold(uint256 _threshold) external onlyOwner {
        threshold = _threshold;
    }

    function setWeightDecay(uint256 _weightDecay) external onlyOwner {
        weightDecay = _weightDecay;
    }

    function setBaseFee(uint256 _baseFee) external onlyOwner {
        baseFee = _baseFee;
    }

    function setN(uint256 _n) external onlyOwner {
        n = _n;
    }
}
