
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { waffle } = require("hardhat");
require("@nomiclabs/hardhat-web3");
const provider = waffle.provider

describe("MockOracle", () => {

	let trading, addrs = [], owner, oracle;

	before(async () => {

		addrs = provider.getWallets();
		owner = addrs[0];
		const oracleContract = await ethers.getContractFactory("MockPikaPriceFeed");
		oracle = await oracleContract.deploy();
	});

	it("get price", async () => {
		await oracle.connect(owner).setTokenForFeed(["0xDf032Bc4B9dC2782Bb09352007D4C57B75160B15"], ["0x8A753747A1Fa494EC906cE90E9f37563A8AF630e"])
		await oracle.connect(owner).setPrices(["0x8A753747A1Fa494EC906cE90E9f37563A8AF630e"], [401000000000])
		await provider.send("evm_increaseTime", [500])
		await provider.send("evm_mine")
		// console.log((await oracle.connect(owner).getPrices(["0x8A753747A1Fa494EC906cE90E9f37563A8AF630e"])).toString())
		// console.log((await oracle.connect(owner).getPrice("0xDf032Bc4B9dC2782Bb09352007D4C57B75160B15")).toString())
	});
});
