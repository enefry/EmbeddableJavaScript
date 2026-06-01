if (!globalThis.EJSStorage) {
  console.log("skip: EJSStorage is unavailable");
} else {
  await EJSStorage.local.setItem("ejsKey", "value-1");
  const value = await EJSStorage.local.getItem("ejsKey");
  if (value !== "value-1") {
    throw new Error(`Storage roundtrip failed: ${value}`);
  }

  await EJSStorage.json.set("ejsJson", { ok: true, n: 7 });
  const json = await EJSStorage.json.get("ejsJson");
  if (!json || json.ok !== true || json.n !== 7) {
    throw new Error("Storage json roundtrip failed");
  }

  await EJSStorage.local.removeItem("ejsKey");
  const removed = await EJSStorage.local.getItem("ejsKey");
  if (removed !== null) {
    throw new Error("Storage removeItem failed");
  }

  console.log("storage ok");
}
