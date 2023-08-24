import {ethers} from "hardhat";

async function main() {
    const StopLoss = await ethers.getContractFactory("StopLoss");
    const stopLoss = await StopLoss.deploy("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    console.log(`stopLoss hash: ${stopLoss.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});

