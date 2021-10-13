pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";

contract MockOracle {
    uint256 public px;
    uint80 roundId = 1000;
    int256 answer = 3000e8;
    uint256 startedAt = 1633435171;
    uint256 updatedAt = 1633435171;
    uint80 answeredInRound = 18446744073709555201;

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function decimals()
        external
        view
        returns (
            uint8
        )
    {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }


}
