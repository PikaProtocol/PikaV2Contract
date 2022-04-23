
const { expect } = require("chai")
const hre = require("hardhat")
const { waffle, ethers } = require("hardhat")
const { utils, BigNumber} = require("ethers");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const provider = waffle.provider

// Assert that actual is less than 1/accuracy difference from expected
function assertAlmostEqual(actual, expected, accuracy = 10000) {
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

describe("PikaTokenGeneration", function () {
    let pikaTgeContract, pikaTge, owner, alice, bob, tom, david, joe, elements, merkleTree, pikaContract, pika;

    before(async function () {

        this.wallets = provider.getWallets()
        owner = this.wallets[0]
        alice = this.wallets[1]
        bob = this.wallets[2]
        tom = this.wallets[3]
        david = this.wallets[4]
        joe = this.wallets[5]
        pikaTgeContract = await hre.ethers.getContractFactory("PikaTokenGeneration")
        pikaContract = await hre.ethers.getContractFactory("Pika")

        pika = await pikaContract.deploy("Pika", "PIKA", "1000000000000000000000000000", owner.address, owner.address)
        await pika.setTransfersAllowed(true);

        const users = [
            {address: tom.address, amount: "100000000000000000"},
            {address: alice.address, amount: "300000000000000000"},
            {address: bob.address, amount: "500000000000000000"},
            {address: david.address, amount: "500000000000000000"}
        ];
        // const users = [owner.address, alice.address, bob.address];

        // equal to MerkleDistributor.sol #keccak256(abi.encodePacked(account, amount));
        // const elements = users.map(x => keccak256(x));
        elements = users.map((x) =>
            utils.solidityKeccak256(["address", "uint256"], [x.address, x.amount])
        );
        merkleTree = new MerkleTree(elements, keccak256, {sort: true});

        const root = merkleTree.getHexRoot();

        const blockNumBefore = await ethers.provider.getBlockNumber();
        const blockBefore = await ethers.provider.getBlock(blockNumBefore);
        const currentTime = blockBefore.timestamp;
        pikaTge = await pikaTgeContract.deploy(pika.address, owner.address, currentTime, currentTime + 86400, currentTime + 86400*2, "1000000000000000000", "100000000000000000000", "100000000000000000", "300000000000000000", "500000000000000000", root); // rinkeby
        await pikaTge.deployed();

        await pika.transfer(pikaTge.address, "100000000000000000000")

    })


    describe("test tge", async function () {
        it("test tge", async function () {
            const tomProof = merkleTree.getHexProof(elements[0]);
            const aliceProof = merkleTree.getHexProof(elements[1]);
            const bobProof = merkleTree.getHexProof(elements[2]);
            const davidProof = merkleTree.getHexProof(elements[3]);

            // whitelist sale
            await expect(pikaTge.connect(joe).depositForWhitelistedAddress(joe.address, tomProof, {from: joe.address, value: "100000000000000000"})).to.be.revertedWith("invalid proof")

            await pikaTge.connect(tom).depositForWhitelistedAddress(tom.address, tomProof, {from: tom.address, value: "100000000000000000"})
            await pikaTge.connect(alice).depositForWhitelistedAddress(alice.address, aliceProof, {from: alice.address, value: "100000000000000000"})
            await pikaTge.connect(bob).depositForWhitelistedAddress(bob.address, bobProof, {from: bob.address, value: "200000000000000000"})
            expect(await pikaTge.depositableLeftWhitelist(tom.address, "100000000000000000")).to.be.equal("0")
            expect(await pikaTge.depositableLeftWhitelist(alice.address, "300000000000000000")).to.be.equal("200000000000000000")
            expect(await pikaTge.depositableLeftWhitelist(bob.address, "500000000000000000")).to.be.equal("300000000000000000")

            await expect(pikaTge.connect(tom).depositForWhitelistedAddress(tom.address, tomProof, {from: tom.address, value: "100000000000000000"})).to.be.revertedWith("user whitelist allocation used up")
            await expect(pikaTge.connect(alice).depositForWhitelistedAddress(alice.address, aliceProof, {from: alice.address, value: "300000000000000000"})).to.be.revertedWith("user whitelist allocation used up")

            await pikaTge.connect(alice).depositForWhitelistedAddress(alice.address, aliceProof, {from: alice.address, value: "200000000000000000"})
            expect(await pikaTge.depositableLeftWhitelist(alice.address, "300000000000000000")).to.be.equal("0")

            expect(await pikaTge.weiDepositedWhitelist()).to.be.equal("600000000000000000")
            expect(await pikaTge.weiDeposited()).to.be.equal("600000000000000000")

            await expect(pikaTge.connect(david).depositForWhitelistedAddress(david.address, davidProof, {from: david.address, value: "500000000000000000"})).to.be.revertedWith("maximum deposits for whitelist reached")

            expect(await pikaTge.getCurrentPikaPrice()).to.be.equal("20000000000000000")

            // public sale
            await provider.send("evm_increaseTime", [86400+100])
            await provider.send("evm_mine")

            // await pikaTge.connect(joe).deposit(joe.address, {from: joe.address, value: "1000000000000000000"}) // 1eth
            await joe.sendTransaction({from: joe.address, to: pikaTge.address, value: "1000000000000000000"});
            expect(await pikaTge.getCurrentPikaPrice()).to.be.equal("20000000000000000")

            await pikaTge.connect(tom).deposit(tom.address, {from: tom.address, value: "1800000000000000000"}) // 1.8eth

            expect(await pikaTge.getCurrentPikaPrice()).to.be.equal("40000000000000000")

            expect(await pikaTge.claimAmountPika(joe.address)).to.be.equal("25000000000000000000")
            expect(await pikaTge.claimAmountPika(tom.address)).to.be.equal("50000000000000000000")

            await provider.send("evm_increaseTime", [86400])
            await provider.send("evm_mine")
            await pikaTge.claim(joe.address)
            await pikaTge.claim(tom.address)
            expect(await pika.balanceOf(joe.address), "25000000000000000000")
            expect(await pika.balanceOf(tom.address), "50000000000000000000")

            const contractEthBalance = await provider.getBalance(pikaTge.address);
            const beforeOwnerBalance = await provider.getBalance(owner.address)
            await pikaTge.connect(owner).withdraw();
            assertAlmostEqual((await provider.getBalance(owner.address)).sub(beforeOwnerBalance), contractEthBalance)

        })
    })
});