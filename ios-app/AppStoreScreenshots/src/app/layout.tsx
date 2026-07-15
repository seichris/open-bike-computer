import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = {
  title: "Let It Ride App Store Screenshots",
  description: "Local generator for App Store screenshots.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
