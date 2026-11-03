require('dotenv').config();
const express = require('express');
const cors = require('cors');  
const connectDB = require('./config/db');

const authRoutes = require('./routes/authRoutes');

const app = express();
// Orígenes permitidos (separados por coma). En Azure: URL de Static Web Apps.
const allowedOrigins = (process.env.CORS_ORIGIN || "http://localhost:3000").split(",").map((o) => o.trim());
app.use(cors({ origin: allowedOrigins, credentials: true }));
app.use(express.json());
app.get("/health", (req, res) => res.send("ok"));

// Connect DB then start
connectDB().then(() => {
  app.use('/api/auth', authRoutes);

  const PORT = process.env.PORT || 4000;
  app.listen(PORT, () => {
    console.log(`🚀 Auth Service running on port ${PORT}`);
  });
});
