if (!globalThis.EJSSystem) {
  throw new Error("EJSSystem unavailable");
}

const cwd = await EJSSystem.cwd();
if (typeof cwd !== "string" || cwd.length === 0) {
  throw new Error("Invalid cwd from EJSSystem.cwd");
}

const platform = await EJSSystem.platform();
if (typeof platform !== "string" || platform.length === 0) {
  throw new Error("Invalid platform from EJSSystem.platform");
}

const hostName = await EJSSystem.hostName();
if (typeof hostName !== "string" || hostName.length === 0) {
  throw new Error("Invalid hostName from EJSSystem.hostName");
}

const userInfo = await EJSSystem.userInfo();
if (!userInfo || typeof userInfo !== "object" || typeof userInfo.username !== "string") {
  throw new Error("Invalid user info from EJSSystem.userInfo");
}

console.log(`platform=${platform}`);
console.log(`cwd=${cwd}`);
console.log(`host=${hostName}`);
console.log(`user=${userInfo.username}`);
