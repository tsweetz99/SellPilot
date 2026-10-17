// eBay redirects the seller's browser here with ?code=...&state=... (or ?error=...).
// Hand the whole query string to the SellPilot app through its custom URL scheme.
const target = "sellpilot://ebay/callback" + window.location.search;
document.getElementById("open").href = target;
window.location.replace(target);
setTimeout(() => { document.getElementById("fallback").hidden = false; }, 1500);
