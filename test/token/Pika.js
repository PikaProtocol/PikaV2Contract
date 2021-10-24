
const { expect } = require("chai")
const hre = require("hardhat")
const { waffle } = require("hardhat")

const provider = waffle.provider

describe("PKS", function () {

  before(async function () {
    this.wallets = provider.getWallets()
    this.owner = this.wallets[0]
    this.alice = this.wallets[1]
    this.bob = this.wallets[2]
    this.pikaContract = await hre.ethers.getContractFactory("Pika")
  })

  beforeEach(async function () {
    this.pika = await this.pikaContract.deploy(this.owner.address, this.owner.address)
  })


  describe("test constructor", async function(){
    it("initial state", async function () {
      expect(await this.pika.totalSupply()).to.be.equal("100000000000000000000000000") // 100m supply
      expect(await this.pika.balanceOf(this.owner.address)).to.be.equal("100000000000000000000000000")
    })
  })

  describe("test mint", async function(){
    it("mint", async function () {
      await this.pika.connect(this.owner).mint(this.alice.address, "10000000000000000000000")
      expect(await this.pika.totalSupply()).to.be.equal("100010000000000000000000000")
      expect(await this.pika.balanceOf(this.alice.address)).to.be.equal("10000000000000000000000")
    })
  })

  describe("test setMinter", async function(){
    it("setMinter", async function () {
      await this.pika.connect(this.owner).setMinter(this.alice.address)
      await expect(this.pika.connect(this.owner).mint(this.bob.address, "10000000000000000000000")).to.be.revertedWith("mint: only the minter can mint")
      await this.pika.connect(this.alice).mint(this.bob.address, "10000000000000000000000")
      expect(await this.pika.totalSupply()).to.be.equal("100010000000000000000000000")
      expect(await this.pika.balanceOf(this.bob.address)).to.be.equal("10000000000000000000000")
    })
  })

  describe("test transfer", async function(){
    it("transfer", async function () {
      await this.pika.connect(this.owner).mint(this.alice.address, "10000000000000000000000")
      await this.pika.connect(this.alice).transfer(this.bob.address, "10000000000000000000000")
      expect(await this.pika.balanceOf(this.alice.address)).to.be.equal("0")
      expect(await this.pika.balanceOf(this.bob.address)).to.be.equal("10000000000000000000000")
    })

    it("transferFrom", async function () {
      await this.pika.connect(this.owner).mint(this.alice.address, "10000000000000000000000")
      await this.pika.connect(this.alice).approve(this.owner.address, "10000000000000000000000")
      await this.pika.connect(this.owner).transferFrom(this.alice.address, this.bob.address, "10000000000000000000000")
      expect(await this.pika.balanceOf(this.alice.address)).to.be.equal("0")
      expect(await this.pika.balanceOf(this.bob.address)).to.be.equal("10000000000000000000000")
    })
  })
})
