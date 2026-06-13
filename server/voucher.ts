import { privateKeyToAccount } from "viem/accounts";

/**
 * EIP-712 voucher signed by the World ID backend signer.
 * MUST match StakeAndAdvance's DOMAIN_SEPARATOR + PERSONHOOD_TYPEHASH:
 *   domain  = { name: "StakeAndAdvance", version: "1", chainId, verifyingContract }
 *   struct  = Personhood(address user, bytes32 nullifierHash, uint64 deadline)
 */
export async function signPersonhoodVoucher(params: {
  signerKey: `0x${string}`;
  chainId: number;
  verifyingContract: `0x${string}`;
  user: `0x${string}`;
  nullifierHash: `0x${string}`;
  deadline: bigint;
}): Promise<`0x${string}`> {
  const account = privateKeyToAccount(params.signerKey);

  return account.signTypedData({
    domain: {
      name: "StakeAndAdvance",
      version: "1",
      chainId: params.chainId,
      verifyingContract: params.verifyingContract,
    },
    types: {
      Personhood: [
        { name: "user", type: "address" },
        { name: "nullifierHash", type: "bytes32" },
        { name: "deadline", type: "uint64" },
      ],
    },
    primaryType: "Personhood",
    message: {
      user: params.user,
      nullifierHash: params.nullifierHash,
      deadline: params.deadline,
    },
  });
}
