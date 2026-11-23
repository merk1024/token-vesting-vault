
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("VestingVault", function () {
  let token, vault;
  let owner, alice, bob, stranger;
  let start;

  const AMOUNT = ethers.parseEther("600");
  const DURATION = 1000;
  const CLIFF = 200;

  beforeEach(async function () {
    [owner, alice, bob, stranger] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("TestToken");
    token = await Token.deploy();
    await token.waitForDeployment();

    const Vault = await ethers.getContractFactory("VestingVault");
    vault = await Vault.deploy(await token.getAddress());
    await vault.waitForDeployment();

    await token.transfer(
      await vault.getAddress(),
      ethers.parseEther("1000")
    );

    start = (await time.latest()) + 100;
  });

  async function createSchedule(
    beneficiary = alice.address,
    amount = AMOUNT,
    revocable = true
  ) {
    await vault.createSchedule(
      beneficiary,
      amount,
      start,
      CLIFF,
      DURATION,
      revocable
    );
  }

  it("1. Owner can create a schedule", async function () {
    await createSchedule();
    expect(await vault.scheduleCount()).to.equal(1n);
  });

  it("2. Non-owner cannot create schedules", async function () {
    await expect(
      vault.connect(alice).createSchedule(
        alice.address, AMOUNT, start, CLIFF, DURATION, true
      )
    ).to.be.reverted;
  });

  it("3. Rejects zero beneficiary", async function () {
    await expect(
      vault.createSchedule(
        ethers.ZeroAddress, AMOUNT, start, CLIFF, DURATION, true
      )
    ).to.be.revertedWith("zero beneficiary");
  });

  it("4. Rejects zero amount", async function () {
    await expect(
      vault.createSchedule(alice.address, 0, start, CLIFF, DURATION, true)
    ).to.be.revertedWith("zero amount");
  });

  it("5. Rejects invalid cliff", async function () {
    await expect(
      vault.createSchedule(alice.address, AMOUNT, start, 2000, 1000, true)
    ).to.be.revertedWith("cliff exceeds duration");
  });

  it("6. Rejects insufficient funding", async function () {
    await expect(
      vault.createSchedule(
        alice.address,
        ethers.parseEther("2000"),
        start, CLIFF, DURATION, true
      )
    ).to.be.revertedWith("insufficient unallocated tokens");
  });

  it("7. Nothing vests before the cliff", async function () {
    await createSchedule();
    await time.increaseTo(start + CLIFF - 1);
    expect(await vault.vestedAmount(1)).to.equal(0n);
  });

  it("8. Tokens vest linearly after the cliff", async function () {
    await createSchedule();
    await time.increaseTo(start + 500);
    expect(await vault.vestedAmount(1)).to.equal(AMOUNT / 2n);
  });

  it("9. All tokens vest after duration", async function () {
    await createSchedule();
    await time.increaseTo(start + DURATION);
    expect(await vault.vestedAmount(1)).to.equal(AMOUNT);
  });

  it("10. Anyone can release vested tokens to beneficiary", async function () {
    await createSchedule();
    await time.increaseTo(start + DURATION);

    await vault.connect(stranger).release(1);

    expect(await token.balanceOf(alice.address)).to.equal(AMOUNT);
    expect(await vault.releasable(1)).to.equal(0n);
    expect(await vault.totalAllocated()).to.equal(0n);
  });

  it("11. Cannot release twice", async function () {
    await createSchedule();
    await time.increaseTo(start + DURATION);

    await vault.release(1);

    await expect(
      vault.release(1)
    ).to.be.revertedWith("nothing to release");
  });

  it("12. Owner can revoke a revocable schedule", async function () {
    await createSchedule();
    await time.increaseTo(start + 500);

    const before = await token.balanceOf(owner.address);

    await vault.revoke(1);

    const schedule = await vault.schedules(1);
    expect(schedule.revoked).to.equal(true);
    expect(await token.balanceOf(owner.address)).to.equal(
      before + AMOUNT / 2n
    );
  });

  it("13. Cannot revoke a non-revocable schedule", async function () {
    await createSchedule(alice.address, AMOUNT, false);

    await expect(
      vault.revoke(1)
    ).to.be.revertedWith("not revocable");
  });

  it("14. Owner can withdraw unallocated tokens", async function () {
    await createSchedule();

    await vault.withdrawUnallocated(owner.address);

    expect(
      await token.balanceOf(await vault.getAddress())
    ).to.equal(AMOUNT);

    expect(await vault.totalAllocated()).to.equal(AMOUNT);
  });

  it("15. Beneficiary can transfer a schedule", async function () {
    await createSchedule();

    await vault.connect(alice).transferSchedule(1, bob.address);

    const schedule = await vault.schedules(1);

    expect(schedule.beneficiary).to.equal(bob.address);
    expect(await vault.schedulesOf(alice.address)).to.deep.equal([]);
    expect(await vault.schedulesOf(bob.address)).to.deep.equal([1n]);
  });
});
