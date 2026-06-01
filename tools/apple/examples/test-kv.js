if (typeof EJSKV === "undefined") {
  console.log("skip: EJSKV is unavailable");
} else {
  await EJSKV.set("ejs/apple/example", "ok");
  const value = new TextDecoder().decode(await EJSKV.get("ejs/apple/example"));
  if (value !== "ok") {
    throw new Error("KV roundtrip failed");
  }

  await EJSKV.delete("ejs/apple/example");
  const missing = await EJSKV.get("ejs/apple/example");
  if (missing !== null) {
    throw new Error("KV delete failed");
  }

  console.log("kv ok");
}
