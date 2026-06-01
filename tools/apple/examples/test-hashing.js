if (!globalThis.EJSHashing) {
  throw new Error("EJSHashing unavailable");
}

const sha256 = await EJSHashing.sha256("abc");
if (sha256 !== "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") {
  throw new Error(`Unexpected sha256: ${sha256}`);
}

const digest = await EJSHashing.digest("sha512", new Uint8Array([97, 98, 99]));
if (digest !== "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f") {
  throw new Error("Unexpected sha512 digest");
}

const base64 = await EJSHashing.sha256("abc", { encoding: "base64" });
if (base64 !== "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=") {
  throw new Error("Unexpected base64 sha256");
}

console.log("hashing ok");
