const twilio = require("twilio");

const accountSid = process.env.TWILIO_ACCOUNT_SID;
const authToken = process.env.TWILIO_AUTH_TOKEN;
const twilioPhoneNumber = process.env.TWILIO_PHONE_NUMBER;

// Si Twilio no está configurado (cuenta opcional en la demo), no se crea el cliente
// para que el servicio pueda arrancar igual; los SMS simplemente se omiten.
const client =
  accountSid && accountSid.startsWith("AC") && authToken
    ? twilio(accountSid, authToken)
    : null;
if (!client) console.warn("⚠️ Twilio no configurado: los SMS se omitirán.");

/**
 * Sends an SMS notification to the customer
 * @param {string} phoneNumber - Customer's phone number
 * @param {string} message - Message content
 */
const sendSmsNotification = async (phoneNumber, message) => {
  if (!client) return;
  try {
    const response = await client.messages.create({
      body: message,
      from: twilioPhoneNumber,
      to: phoneNumber,
    });
    console.log(`SMS sent to ${phoneNumber}: ${response.sid}`);
  } catch (error) {
    console.error("❌ Error sending SMS:", error.message);
  }
};

module.exports = { sendSmsNotification };
