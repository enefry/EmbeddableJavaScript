let response = await fetch("data:text/plain,apple-cli-fetch");
let body = await response.text();

if (!response.ok || body !== "apple-cli-fetch") {
  throw new Error("Data URL fetch mismatch");
}

console.log(`fetch ok len=${body.length}`);

response = await fetch("https://www.baidu.com");
body = await response.text();
console.log(`resp:${typeof (response)}, body=${body}`);
console.log(`resp:${JSON.stringify({
  ok: response.ok,
  status: response.status,
  statusText: response.statusText,
  url: response.url,
  redirected: response.redirected,
  type: response.type,
  bodyUsed: response.bodyUsed,
})}, body=${body}`);

console.log(`fetch ok len=${body.length}`);
