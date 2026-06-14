export const ARC_TESTNET_CHAIN_ID = 5_042_002;

export const ARC_TESTNET_USDC = "0x3600000000000000000000000000000000000000" as const;

// Defaults to the live Arc testnet deployment so a frontend resolves it without env wiring.
export const STAKE_AND_ADVANCE_ADDRESS =
  (process.env.STAKE_AND_ADVANCE_ADDRESS || "0xC18036FfFfa6D5A861EbA9bd1084b68BC3321c40") as `0x${string}`;

export const KEYSTONE_FORWARDER =
  (process.env.KEYSTONE_FORWARDER || "0x0000000000000000000000000000000000000000") as `0x${string}`;
