// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFeeCalculator {
    function getFee(address token, address user) external view returns (int256);
}
