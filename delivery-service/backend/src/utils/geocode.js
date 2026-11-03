import fetch from "node-fetch";

// La clave y el país se configuran por variables de entorno. El código original
// tenía fijo el país Sri Lanka (lk), por lo que las direcciones de Ecuador fallaban.
const OPENCAGE_API_KEY = process.env.OPENCAGE_API_KEY || 'b831a2728a524c00a5c1e031e3862886';
const GEOCODE_COUNTRY = process.env.GEOCODE_COUNTRY || 'ec';

export async function geocodeAddress(address) {
  const country = GEOCODE_COUNTRY ? `&countrycode=${GEOCODE_COUNTRY}` : '';
  const url = `https://api.opencagedata.com/geocode/v1/json?q=${encodeURIComponent(address)}${country}&key=${OPENCAGE_API_KEY}`;

  const response = await fetch(url);
  const data = await response.json();

  if (data.results && data.results.length > 0) {
    const { lat, lng } = data.results[0].geometry;
    return [lng, lat]; // [longitude, latitude]
  } else {
    throw new Error('Address not found');
  }
}
