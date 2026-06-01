if (!globalThis.EJSUUID) {
  throw new Error("EJSUUID unavailable");
}

const idA = await EJSUUID.v4();
const idB = await EJSUUID.randomUUID();

if (!EJSUUID.validate(idA) || !EJSUUID.validate(idB)) {
  throw new Error("UUID validation failed");
}

if (EJSUUID.validate("not-a-uuid")) {
  throw new Error("Invalid UUID should fail validation");
}

console.log(`uuid-a=${idA}`);
console.log(`uuid-b=${idB}`);
