# EJSIPAddr

`modules/stdlib/ipaddr` is an optional pure-JavaScript IP address helper. It
installs `globalThis.EJSIPAddr` and does not register a native provider or
require network permission.

## JavaScript API

```js
EJSIPAddr.isValid("192.0.2.1"); // true
EJSIPAddr.isValidIPv4("127.0.0.1"); // true
EJSIPAddr.isValidIPv6("::1"); // true
EJSIPAddr.isValidCIDR("127.0.0.0/8"); // true

const address = EJSIPAddr.parse("2001:db8::1");
const cidr = EJSIPAddr.parseCIDR("127.0.0.0/8");

EJSIPAddr.contains(cidr, "127.0.0.1"); // true
EJSIPAddr.normalize("2001:0db8:0:0:0:0:0:1"); // "2001:db8::1"
```

IPv4 parsing is strict dotted decimal and rejects octal, hexadecimal, missing
octets, and out-of-range octets. IPv6 parsing supports `::` compression,
embedded IPv4 tail syntax such as `::ffff:192.0.2.128`, and scoped addresses
such as `fe80::1%lo0`; parsed scoped addresses expose `scopeId`. `contains`
accepts CIDR strings or parsed CIDR objects and rejects malformed object-form
CIDRs.

## Apple Notes

The Apple add-on only evaluates the bundled JavaScript wrapper. It has no native
provider, no network access, and no dependency on `ejs.network` policy.

## Verification

```sh
node --check modules/stdlib/ipaddr/js/ipaddr.js
node tests/js/network_js_test.js
cmake --build build --target ejs_stdlib_apple_test
ctest --test-dir build -R ejs_stdlib_apple_test --output-on-failure
```
