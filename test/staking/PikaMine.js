
const { expect } = require("chai")
const hre = require("hardhat")
const { waffle, ethers} = require("hardhat")
const {BigNumber} = require("ethers");

const provider = waffle.provider

// Assert that actual is less than 1/accuracy difference from expected
function assertAlmostEqual(actual, expected, accuracy = 100000) {
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


describe("PikaMine", function () {
    let pika, esPika, vePika, pikaMine, vePikaFeeReward, vePikaTokenReward, testPikaPerp, owner, alice, bob, usdc;
    before(async function () {
        this.wallets = provider.getWallets()
        owner = this.wallets[0]
        alice = this.wallets[1]
        bob = this.wallets[2]
        const pikaContract = await hre.ethers.getContractFactory("Pika")
        const pikaMineContract = await hre.ethers.getContractFactory("PikaMine")
        const vePikaContract = await hre.ethers.getContractFactory("VePika")
        const testPikaPerpContract = await hre.ethers.getContractFactory("TestPikaPerp")
        const usdcContract = await ethers.getContractFactory("TestUSDC");
        usdc = await usdcContract.deploy();
        await usdc.mint(owner.address, 1000000000000);

        pika = await pikaContract.deploy("Pika", "PIKA", "1000000000000000000000000000", owner.address, owner.address)
        await pika.setTransfersAllowed(true);
        await pika.connect(owner).transfer(alice.address, "3000000000000000000000") //3000 pika
        await pika.connect(owner).transfer(bob.address, "3000000000000000000000") //3000 pika

        esPika = await pikaContract.deploy("Pika", "PIKA", "1000000000000000000000000000", owner.address, owner.address)
        await esPika.connect(owner).grantRole("0x9143236d81225394f3bd65b44e6e29fdf4d7ba0773d9bb3f5cc15eb80ba37777", owner.address)

        pikaMine = await pikaMineContract.connect(owner).deploy();
        await pikaMine.initialize(
            pika.address
        )
        vePika = await vePikaContract.deploy(pikaMine.address)

        const vePikaFeeRewardContract = await ethers.getContractFactory("VePikaFeeReward");
        vePikaFeeReward = await vePikaFeeRewardContract.deploy(vePika.address, usdc.address);

        testPikaPerp = await testPikaPerpContract.connect(owner).deploy();
        await vePikaFeeReward.setPikaPerp(testPikaPerp.address);

        const vePikaTokenRewardContract = await ethers.getContractFactory("VePikaTokenReward");
        vePikaTokenReward = await vePikaTokenRewardContract.deploy(vePika.address, esPika.address, pikaMine.address);
        await esPika.connect(owner).grantRole("0x9143236d81225394f3bd65b44e6e29fdf4d7ba0773d9bb3f5cc15eb80ba37777", vePikaTokenReward.address)
        await esPika.connect(owner).approve(vePikaTokenReward.address, "100000000000000000000000")

        await pikaMine.setRewardPools([vePikaFeeReward.address, vePikaFeeReward.address, vePikaTokenReward.address])
    })

    describe("test pikaMine", async function(){
        it("deposit", async function () {
            vePikaTokenReward.connect(owner).queueNewRewards("1000000000000000000000"); //1000 esPika

            await pika.connect(alice).approve(pikaMine.address, "100000000000000000000000")
            await pika.connect(bob).approve(pikaMine.address, "100000000000000000000000")
            await pikaMine.connect(alice).deposit("1000000000000000000000", 0)
            await pikaMine.connect(alice).deposit("1000000000000000000000", 2)
            // console.log("total supply", await vePika.totalSupply())
            expect(await vePikaFeeReward.getClaimableReward(alice.address)).to.be.equal("2000000000000000000")
            await pikaMine.connect(bob).deposit("2000000000000000000000", 3)
            await vePikaFeeReward.updateReward(bob.address)
            expect(await vePika.balanceOf(alice.address)).to.equal("500000000000000000000");
            expect(await vePika.balanceOf(bob.address)).to.equal("2000000000000000000000");

            await provider.send("evm_increaseTime", [86400*30])
            await provider.send("evm_mine")

            expect(await vePikaFeeReward.getClaimableReward(alice.address)).to.be.equal("4200000000000000000")
            expect(await vePikaFeeReward.getClaimableReward(bob.address)).to.be.equal("800000000000000000")
            assertAlmostEqual((await vePikaTokenReward.earned(alice.address)).mul("4"), await vePikaTokenReward.earned(bob.address))
            await vePikaTokenReward.connect(alice).getReward();
            await vePikaTokenReward.connect(bob).getReward();
            assertAlmostEqual((await esPika.balanceOf(alice.address)).mul("4"), await esPika.balanceOf(bob.address))


            await expect(pikaMine.connect(alice).withdraw("1000000000000000000000", 2)).to.be.revertedWith("Position is still locked")
            await pikaMine.connect(alice).withdraw("1000000000000000000000", 1);
            expect(await pikaMine.depositedAll(alice.address)).to.be.equal("1000000000000000000000")
            expect(await vePika.balanceOf(alice.address)).to.equal("400000000000000000000");

            await pikaMine.connect(alice).deposit("1000000000000000000000", 3)
            expect(await pikaMine.depositedAll(alice.address)).to.be.equal("2000000000000000000000")
            expect(await vePika.balanceOf(alice.address)).to.equal("1400000000000000000000");
            await vePikaTokenReward.connect(owner).queueNewRewards("1000000000000000000000"); //1000 esPika

            await provider.send("evm_increaseTime", [86400*180])
            await provider.send("evm_mine")
            expect(await pikaMine.unlockedAll(alice.address)).to.be.equal("1000000000000000000000")
            expect(await pikaMine.unlockedAll(bob.address)).to.be.equal("0")
            assertAlmostEqual((await vePikaTokenReward.earned(alice.address)).div(14).mul(20), await vePikaTokenReward.earned(bob.address))

            await provider.send("evm_increaseTime", [86400*180])
            await provider.send("evm_mine")
            expect(await pikaMine.unlockedAll(alice.address)).to.be.equal("1000000000000000000000")
            expect(await pikaMine.unlockedAll(bob.address)).to.be.equal("2000000000000000000000")
            const beforeWithdrawBob = await pika.balanceOf(bob.address)
            await pikaMine.connect(bob).withdraw("2000000000000000000000", 1);
            assertAlmostEqual((await pika.balanceOf(bob.address)).sub(beforeWithdrawBob), "2000000000000000000000")

            await provider.send("evm_increaseTime", [86400*5])
            await provider.send("evm_mine")
            expect(await pikaMine.unlockedAll(bob.address)).to.be.equal("0")
            const beforeWithdrawAlice = await pika.balanceOf(alice.address)

            await pikaMine.connect(alice).withdraw("1000000000000000000000", 3);
            assertAlmostEqual((await pika.balanceOf(alice.address)).sub(beforeWithdrawAlice), "1000000000000000000000")

        })
    })
})
