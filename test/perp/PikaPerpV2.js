
const { ethers } = require("hardhat");
const { expect } = require("chai");
// const { BigNumber } = require('bignumber.js');
const { waffle } = require("hardhat");
const { parseUnits, formatUnits } = require('./utils.js');
const { utils, BigNumber } = require("ethers")
require("@nomiclabs/hardhat-web3");
const provider = waffle.provider

const maxShift = 0.003e8; // max shift (shift is used adjust the price to balance the longs and shorts)


let currentPositionId = 0;
const starting_balance = parseUnits(10000);
let latestPrice = 3000e8;
function _calculatePriceWithFee(price, isLong) {
	if (isLong) {
		return Math.round(price * (1 + PRODUCTS[1].fee/10000));
	} else {
		return Math.round(price * (1 - PRODUCTS[1].fee/10000));
	}
}

function getLatestPrice(feed, productId) {
	return latestPrice;
}

function _calculatePriceWithFee(feed, fee, isLong, openInterestLong, openInterestShort, maxExposure, reserve, amount) {
	let oraclePrice = getLatestPrice(feed, 0);

	let shift = (openInterestLong - openInterestShort) * maxShift / maxExposure;
	if (isLong) {
		let slippage = parseInt((reserve * reserve / (reserve - amount) - reserve) * (10**8) / amount);
		// console.log("slippage", slippage)
		slippage = shift >= 0 ?parseInt(slippage + shift) : Math.ceil(slippage - (-1 * shift / 2));
		// console.log("shift", shift)
		// console.log("slippage", slippage)
		let price = oraclePrice * slippage / (10**8);
		// console.log("price", price);
		// console.log("price", price + price * fee / 10**4);
		return Math.ceil(price + price * fee / 10**4);
	} else {
		let slippage = parseInt((reserve - reserve * reserve / (reserve + amount)) * (10**8) / amount);
		// console.log("slippage", slippage)
		slippage = shift >= 0 ? parseInt(slippage + shift / 2) : parseInt(slippage - (-1 * shift));
		// console.log("shift", shift)
		// console.log("slippage", slippage)
		let price = oraclePrice * slippage / (10**8);
		// console.log("oraclePrice", oraclePrice);
		// console.log("price", price);
		// console.log("price", price - price * fee / 10**4);
		return Math.ceil(price - price * fee / 10**4);
	}
}

function getPositionId(account, productId, isLong, isPika) {
	return web3.utils.soliditySha3(
		{t: 'address', v: account},
		{t: 'uint256', v: productId},
		{t: 'bool', v: isLong},
		{t: 'bool', v: isPika}
	);
}

// Assert that actual is less than 1/accuracy difference from expected
function assertAlmostEqual(actual, expected, accuracy = 10000000) {
	const expectedBN = BigNumber.isBigNumber(expected) ? expected : BigNumber.from(expected)
	const actualBN = BigNumber.isBigNumber(actual) ? actual : BigNumber.from(actual)
	const diffBN = expectedBN.gt(actualBN) ? expectedBN.sub(actualBN) : actualBN.sub(expectedBN)
	if (expectedBN.gt(0)) {
		return expect(
			diffBN).to.lt(expectedBN.div(BigNumber.from(accuracy.toString()))
		)
	}
	return expect(
		diffBN).to.lt(-1 * expectedBN.div(BigNumber.from(accuracy.toString()))
	)
}


describe("Trading", () => {

	let Trading, addrs = [], owner, Pika, Oracle;

	before(async () => {

		addrs = provider.getWallets();
		owner = addrs[0];

        const PikaContract = await ethers.getContractFactory("Pika");
        Pika = await PikaContract.deploy(1);
		const TradingContract = await ethers.getContractFactory("PikaPerpV2");
		Trading = await TradingContract.deploy(Pika.address);
		await Pika.grantRole(await Pika.MINTER_ROLE(), Trading.address);
		await Pika.grantRole(await Pika.BURNER_ROLE(), Trading.address);
//     this.tokenERC = await hre.ethers.getContractFactory("SimpleERC20")

		const OracleContract = await ethers.getContractFactory("MockOracle");
		Oracle = await OracleContract.deploy();

		let v = [
			2500000000, //25eth
			0,
			0,
			0,
			0,
			0,
			60,
			30,
			4000
		]

		await Trading.updateVault(v);

		let p = [
			Oracle.address, // chainlink
			50e8,
			0.1 * 100, // 0.1%
			true,
			300e8,
			0,
			0,
			300,
			120,
			60,
			80 * 100, // 80%
			0,
			5000e8
		]
		// add products
		await Trading.addProduct(1, p);

	});

	it("Owner should be set", async () => {
		expect(await Trading.owner()).to.equal(owner.address);
	});


	it("Should fail setting owner from other address", async () => {
		await expect(Trading.connect(addrs[1]).setOwner(addrs[1].address)).to.be.revertedWith('!owner');
	});

	// it("Should set owner", async () => {
	// 	expect(await Trading.setOwner(addrs[1].address)).to.emit(Trading, "OwnerUpdated").withArgs(addrs[1].address);
	// });

	it("Action to change token balance", async () => {
		// token.transfer(walletTo.address, 200)).to.changeTokenBalances(token, [wallet, walletTo], [-200, 200]);
		// token.transferFrom(wallet.address, walletTo.address, 200)).to.changeTokenBalance(token, walletTo, 200);
	});


	describe("trade", () => {


		const productId = 1;
		const margin = 1e8; // 1eth
		const leverage = 10e8;
		const userId = 1;

		before(async () => {
			await Trading.connect(addrs[2]).stake({from: addrs[2].address, value: "1000000000000000000"});
		})

		it(`long positions`, async () => {

			const user = addrs[userId].address;

			const balance_user = await provider.getBalance(user);
			const balance_contract = await provider.getBalance(Trading.address);

			// 1. open long
			const priceWithFee1 = _calculatePriceWithFee(Oracle.address, 10, true, 0, 0, 300e8, 5000e8, margin*leverage/1e8);
			const gasPrice = 3e8;
			const tx1 = await Trading.connect(addrs[userId]).openPosition(productId, true, leverage.toString(), false, {from: addrs[userId].address, value: (margin*1e10).toString(), gasPrice: gasPrice.toString()});
			const receipt = await provider.getTransactionReceipt(tx1.hash);
			const gasCost = parseInt(receipt.gasUsed) * (gasPrice);

			let positionId = getPositionId(user, productId, true, false);
			expect(await tx1).to.emit(Trading, "NewPosition").withArgs(positionId, user, productId, true, priceWithFee1.toString(), margin.toString(), leverage.toString(), false);

			// Check balances
			assertAlmostEqual(await provider.getBalance(user), (balance_user - margin*1e10 - gasCost).toLocaleString('fullwide', {useGrouping:false}))
			assertAlmostEqual(await provider.getBalance(Trading.address), (balance_contract.add(BigNumber.from(margin).mul(1e10))))

			// // Check user positions
			const position1 = (await Trading.getPositions([positionId]))[0];
			expect(position1.productId).to.equal(productId);
			expect(position1.owner).to.equal(user);
			expect(position1.isLong).to.equal(true);
			expect(position1.isPika).to.equal(false);
			expect(position1.margin).to.equal(margin);
			expect(position1.leverage).to.equal(leverage);
			assertAlmostEqual(position1.price, priceWithFee1);
			console.log("after open long", (await provider.getBalance(Trading.address)).div(1e10).toString());

			// 2. increase position
			const leverage2 = parseUnits(20)
			const priceWithFee2 = _calculatePriceWithFee(Oracle.address, 10, true, margin*leverage/1e8, 0, 300e8, 5000e8, margin*leverage2/1e8);
			await Trading.connect(addrs[userId]).openPosition(productId, true, leverage2.toString(), false, {from: addrs[userId].address, value: (margin*1e10).toString(), gasPrice: gasPrice.toString()});
			const position2 = (await Trading.getPositions([positionId]))[0];
			expect(position2.margin).to.equal(margin*2);
			expect(position2.leverage).to.equal(leverage*1.5);
			assertAlmostEqual(position2.price, ((priceWithFee1+priceWithFee2*2)/3).toFixed(0));
			console.log("after increase long", (await provider.getBalance(Trading.address)).div(1e10).toString());

			// 3. close long before minProfitTime with profit less than threshold
			await provider.send("evm_increaseTime", [500])
			latestPrice = 3035e8;
			const priceWithFee3 = _calculatePriceWithFee(Oracle.address, 10, false, 3*margin*leverage/1e8, 0, 300e8, 5000e8, 3*margin*leverage/1e8);
			await Oracle.setAnswer(3035e8);
			// await Trading.connect(addrs[1]).setFees(100, 0.01e8);
			const tx3 = await Trading.connect(addrs[userId]).closePosition(positionId, 3*margin, false, {from: addrs[userId].address});
			expect(await tx3).to.emit(Trading, "ClosePosition").withArgs(positionId, user, productId, true, priceWithFee3.toString(), position2.price, (2*margin).toString(), (leverage*1.5).toString(), 0, false, false);
			console.log("after close long", (await provider.getBalance(Trading.address)).div(1e10).toString());
		});

		it(`short positions`, async () => {

			const user = addrs[userId].address;

			const balance_user = await provider.getBalance(user);
			const balance_contract = await provider.getBalance(Trading.address);

			// 1. open short
			const priceWithFee1 = _calculatePriceWithFee(Oracle.address, 10, false, 0, 0, 300e8, 5000e8, margin*leverage/1e8);
			const gasPrice = 3e8;
			const tx1 = await Trading.connect(addrs[userId]).openPosition(productId, false, leverage.toString(), false, {from: addrs[userId].address, value: (margin*1e10).toString(), gasPrice: gasPrice.toString()});
			const receipt = await provider.getTransactionReceipt(tx1.hash);
			const gasCost = parseInt(receipt.gasUsed) * (gasPrice);

			let positionId = getPositionId(user, productId, false, false);
			expect(await tx1).to.emit(Trading, "NewPosition").withArgs(positionId, user, productId, false, priceWithFee1.toString(), margin.toString(), leverage.toString(), false);

			// Check balances
			assertAlmostEqual(await provider.getBalance(user), (balance_user - margin*1e10 - gasCost).toLocaleString('fullwide', {useGrouping:false}))
			assertAlmostEqual(await provider.getBalance(Trading.address), (balance_contract.add(BigNumber.from(margin).mul(1e10))))

			// // Check user positions
			const position1 = (await Trading.getPositions([positionId]))[0];
			expect(position1.productId).to.equal(productId);
			expect(position1.owner).to.equal(user);
			expect(position1.isLong).to.equal(false);
			expect(position1.isPika).to.equal(false);
			expect(position1.margin).to.equal(margin);
			expect(position1.leverage).to.equal(leverage);
			assertAlmostEqual(position1.price, priceWithFee1);
			console.log("after open short", (await provider.getBalance(Trading.address)).div(1e10).toString());

			// 2. increase position
			const leverage2 = parseUnits(20)
			const priceWithFee2 = _calculatePriceWithFee(Oracle.address, 10, false, 0, margin*leverage/1e8, 300e8, 5000e8, margin*leverage2/1e8);
			await Trading.connect(addrs[userId]).openPosition(productId, false, leverage2.toString(), false, {from: addrs[userId].address, value: (margin*1e10).toString(), gasPrice: gasPrice.toString()});
			const position2 = (await Trading.getPositions([positionId]))[0];
			expect(position2.margin).to.equal(margin*2);
			expect(position2.leverage).to.equal(leverage*1.5);
			// console.log("postion2 price", position2.price.toString());
			assertAlmostEqual(position2.price, ((priceWithFee1+priceWithFee2*2)/3).toFixed(0));
			console.log("after increase short", (await provider.getBalance(Trading.address)).div(1e10).toString());

			// 3. close short before minProfitTime with profit less than threshold
			console.log("closing short")
			await provider.send("evm_increaseTime", [200])
			latestPrice = 3000e8;
			const priceWithFee3 = _calculatePriceWithFee(Oracle.address, 10, true, 0, 3*margin*leverage/1e8, 300e8, 5000e8, 3*margin*leverage/1e8);
			await Oracle.setAnswer(3000e8);
			await Trading.setFees(0.01e8, 0);
			const tx3 = await Trading.connect(addrs[userId]).closePosition(positionId, 3*margin, false, {from: addrs[userId].address});
			console.log("after close short", (await provider.getBalance(Trading.address)).div(1e10).toString());
			// expect(await tx3).to.emit(Trading, "ClosePosition").withArgs(positionId, user, productId, true, priceWithFee3.toString(), position2.price, (2*margin).toString(), (leverage*1.5).toString(), 0, false, false);
		});

		// it(`pika`, async () => {
		//
		// 	const user = addrs[userId].address;
		//
		// 	const balance_user = await provider.getBalance(user);
		// 	const balance_contract = await provider.getBalance(Trading.address);
		// 	const leverage = 1e8;
		//
		// 	// 1. mint pika
		// 	const priceWithFee1 = _calculatePriceWithFee(Oracle.address, 10, false, 0, 0, 300e8, 5000e8, margin*leverage/1e8);
		// 	const gasPrice = 3e8;
		// 	const tx1 = await Trading.connect(addrs[userId]).openPosition(productId, false, leverage.toString(), true, {from: addrs[userId].address, value: (margin*1e10).toString(), gasPrice: gasPrice.toString()});
		//
		// 	const receipt = await provider.getTransactionReceipt(tx1.hash);
		// 	const gasCost = parseInt(receipt.gasUsed) * (gasPrice);
		//
		// 	let positionId = getPositionId(user, productId, false, true);
		//
		// 	// expect(await tx1).to.emit(Trading, "NewPosition").withArgs(positionId, user, productId, false, priceWithFee1.toString(), margin.toString(), leverage.toString(), true);
		//
		// 	// Check balances
		// 	assertAlmostEqual(await provider.getBalance(user), (balance_user - margin*1e10 - gasCost).toLocaleString('fullwide', {useGrouping:false}))
		// 	assertAlmostEqual(await provider.getBalance(Trading.address), (balance_contract.add(BigNumber.from(margin).mul(1e10))))
		//
		// 	// // Check user positions
		// 	const position1 = (await Trading.getPositions([positionId]))[0];
		// 	expect(position1.productId).to.equal(productId);
		// 	expect(position1.owner).to.equal(user);
		// 	expect(position1.isLong).to.equal(false);
		// 	expect(position1.isPika).to.equal(true);
		// 	expect(position1.margin).to.equal(margin);
		// 	expect(position1.leverage).to.equal(leverage);
		// 	assertAlmostEqual(position1.price, priceWithFee1);
		//
		// 	console.log("after open pika", (await provider.getBalance(Trading.address)).div(1e10).toString());
		//
		//
		// 	// 2. settle position
		// 	await provider.send("evm_increaseTime", [301]);
		// 	await Trading.settlePositions([positionId]);
		// 	// console.log("expect", (await Pika.balanceOf(position1.owner)).toString(), (position1.price.mul(position1.margin).mul(BigNumber.from(100))).toString());
		// 	const pikaAmount = await Pika.balanceOf(position1.owner);
		// 	assertAlmostEqual(pikaAmount, position1.price.mul(position1.margin).mul(BigNumber.from(100)));
		// 	const position2 = (await Trading.getPositions([positionId]))[0];
		// 	expect(position2.margin).to.equal(0);
		//
		// 	// 3. close pika position
		// 	await provider.send("evm_increaseTime", [86400])
		// 	latestPrice = 2900e8;
		// 	const priceWithFee3 = _calculatePriceWithFee(Oracle.address, 10, true, 0, 1e8, 300e8, 5000e8, margin*leverage/1e8);
		// 	await Oracle.setAnswer(2900e8);
		// 	await Trading.setFees(0.01e8, 0.01e8);
		// 	const tx3 = await Trading.connect(addrs[userId]).closePikaPosition(pikaAmount.div(1e10), false);
		// 	expect(await tx3).to.emit(Trading, "BurnPika").withArgs(user, pikaAmount.div(1e10));
		// 	expect(await Pika.balanceOf(user)).to.equal(0);
		// 	console.log("after close pika", (await provider.getBalance(Trading.address)).div(1e10).toString());
		//
		// });

		it(`stake`, async () => {
			await provider.send("evm_increaseTime", [80])
			await Trading.connect(addrs[2]).redeem(1, 100000000);

			// await Trading.connect(addrs[2]).stake({from: addrs[2].address, value: "1000000000000000000"});
			// const vault = await Trading.getVault();
			// console.log(vault)
			// expect(vault.staked).to.equal("100000000");
			// expect(vault.balance).to.equal("100000000");
			// expect(vault.shares).to.equal("100000000");
			// console.log("stakedbalance", await provider.getBalance(Trading.address))
		})

	});

	describe("vault", () => {
		const productId = 1;
		const margin = 1e8; // 1eth
		const leverage = 10e8;
		const userId = 1;

		// beforeEach(async () => {
		// 	let v = [
		// 		2500000000, //25eth
		// 		0,
		// 		0,
		// 		0,
		// 		0,
		// 		0,
		// 		60,
		// 		30,
		// 		4000
		// 	]
		// 	// const owner = await Trading.owner();
		// 	console.log(addrs[2].address)
		// })

		// it(`stake`, async () => {
		// 	await Trading.connect(addrs[2]).stake({from: addrs[2].address, value: "1000000000000000000"});
		// 	const vault = await Trading.getVault();
		// 	console.log(vault)
		// 	expect(vault.staked).to.equal("100000000");
		// 	expect(vault.balance).to.equal("100000000");
		// 	expect(vault.shares).to.equal("100000000");
		// 	console.log("stakedbalance", await provider.getBalance(Trading.address))
		// })

	})


	// test user methods & settlement
	// test vault methods
	// test owner methods
	// test liquidation
	// test getters
	// for each method have a describe block testing each case (good, error cases, and events emitted, balances changed)

});
