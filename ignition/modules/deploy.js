const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  const assert = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; // USDC address
  const vault = ["0x616a4E1db48e22028f6bbf20444Cd3b8e3273738"];  // Vault address

  const ContractFactory = await ethers.getContractFactory("UserVault_V3");
  const contract = await ContractFactory.deploy(deployer.address, deployer.address, assert, vault, deployer.address, 100, 10e6);

  console.log("UserVault_V3 address:", contract.target);

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error deploying contract:", error);
    process.exit(1);
  });