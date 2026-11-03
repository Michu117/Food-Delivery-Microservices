// src/pages/TrackOrder.js
import { useEffect, useState } from "react";
import { io } from "socket.io-client";
import { MapContainer, TileLayer, Marker, Polyline } from "react-leaflet";
import L from "leaflet";
import "leaflet/dist/leaflet.css";

// WebSocket connection
const socket = io(process.env.REACT_APP_SOCKET_ORIGIN || "http://localhost:5003", {
  path: process.env.REACT_APP_SOCKET_PATH || "/socket.io",
});

// Custom Driver Icon
const driverIcon = new L.Icon({
  iconUrl: "https://cdn-icons-png.flaticon.com/512/684/684908.png",
  iconSize: [40, 40],
});

export default function TrackOrder({ orderId }) {
  const [location, setLocation] = useState(null);
  const [path, setPath] = useState([]);

  useEffect(() => {
    socket.on(`location-${orderId}`, (data) => {
      console.log("🚚 New Driver Location:", data);
      setLocation(data);
      setPath(prevPath => [...prevPath, [data.lat, data.lng]]);
    });

    return () => socket.off(`location-${orderId}`);
  }, [orderId]);

  if (!location) {
    return <p style={{ padding: "2rem", textAlign: "center" }}>Waiting for driver location... 🕒</p>;
  }

  return (
    <div style={{ height: "100vh" }}>
      <MapContainer center={[location.lat, location.lng]} zoom={15} style={{ height: "100%", width: "100%" }}>
        <TileLayer
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
          attribution="© OpenStreetMap contributors"
        />
        {/* Driver Marker */}
        <Marker position={[location.lat, location.lng]} icon={driverIcon} />

        {/* Path */}
        {path.length > 1 && (
          <Polyline positions={path} color="blue" weight={3} />
        )}
      </MapContainer>
    </div>
  );
}
