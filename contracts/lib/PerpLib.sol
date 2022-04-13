// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../oracle/IOracle.sol";
import '../perp/IFeeCalculator.sol';

library PerpLib {
    uint256 public constant BASE = 10**8;

    function _canTakeProfit(
        bool isLong,
        uint256 positionTimestamp,
        uint256 positionOraclePrice,
        uint256 oraclePrice,
        uint256 minPriceChange,
        uint256 minProfitTime
    ) internal view returns(bool) {
        if (block.timestamp > positionTimestamp + minProfitTime) {
            return true;
        } else if (isLong && oraclePrice > positionOraclePrice * (1e4 + minPriceChange) / 1e4) {
            return true;
        } else if (!isLong && oraclePrice < positionOraclePrice * (1e4 - minPriceChange) / 1e4) {
            return true;
        }
        return false;
    }

    function _checkLiquidation(
        bool isLong,
        uint256 positionPrice,
        uint256 positionLeverage,
        uint256 price,
        uint256 liquidationThreshold
    ) internal pure returns (bool) {

        uint256 liquidationPrice;
        if (isLong) {
            liquidationPrice = positionPrice - positionPrice * liquidationThreshold * 10**4 / positionLeverage;
        } else {
            liquidationPrice = positionPrice + positionPrice * liquidationThreshold * 10**4 / positionLeverage;
        }

        if (isLong && price <= liquidationPrice || !isLong && price >= liquidationPrice) {
            return true;
        } else {
            return false;
        }
    }

    function _getPnl(
        bool isLong,
        uint256 positionPrice,
        uint256 positionLeverage,
        uint256 margin,
        uint256 price
    ) internal view returns(int256 _pnl) {
        bool pnlIsNegative;
        uint256 pnl;
        if (isLong) {
            if (price >= positionPrice) {
                pnl = margin * positionLeverage * (price - positionPrice) / positionPrice / BASE;
            } else {
                pnl = margin * positionLeverage * (positionPrice - price) / positionPrice / BASE;
                pnlIsNegative = true;
            }
        } else {
            if (price > positionPrice) {
                pnl = margin * positionLeverage * (price - positionPrice) / positionPrice / BASE;
                pnlIsNegative = true;
            } else {
                pnl = margin * positionLeverage * (positionPrice - price) / positionPrice / BASE;
            }
        }

        if (pnlIsNegative) {
            _pnl = -1 * int256(pnl);
        } else {
            _pnl = int256(pnl);
        }

        return _pnl;
    }

    function _getFeeRate(
        uint256 fee,
        address productToken,
        address user,
        address feeCalculator
    ) view internal returns(uint256) {
        int256 dynamicFee = IFeeCalculator(feeCalculator).getFee(productToken, user);
        return dynamicFee > 0 ? fee + uint256(dynamicFee) : fee - uint256(-1*dynamicFee);
    }

    function _getRealMarginAndFee(
        uint256 marginAndFee,
        uint256 leverage,
        uint256 fee,
        address productToken,
        address user,
        address feeCalculator
    ) internal view returns(uint256, uint256) {
        uint256 margin = marginAndFee / (1 + _getFeeRate(fee, productToken, user, feeCalculator) * leverage);
        return (margin, marginAndFee - margin);
    }

    function _calculatePrice(
        address productToken,
        bool isLong,
        uint256 openInterestLong,
        uint256 openInterestShort,
        uint256 maxExposure,
        uint256 reserve,
        uint256 amount,
        uint256 maxShift,
        uint256 oraclePrice
    ) internal view returns(uint256) {
        int256 shift = (int256(openInterestLong) - int256(openInterestShort)) * int256(maxShift) / int256(maxExposure);
        if (isLong) {
            uint256 slippage = (reserve * reserve / (reserve - amount) - reserve) * BASE / amount;
            slippage = shift >= 0 ? slippage + uint256(shift) : slippage - uint256(-1 * shift) / 2;
            return oraclePrice * slippage / BASE;
        } else {
            uint256 slippage = (reserve - reserve * reserve / (reserve + amount)) * BASE / amount;
            slippage = shift >= 0 ? slippage + uint256(shift) / 2 : slippage - uint256(-1 * shift);
            return oraclePrice * slippage / BASE;
        }
    }
}
