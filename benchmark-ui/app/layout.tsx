import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Voiceprint — Luxit Inference Lab",
  description: "Record once and benchmark local speech-to-text engines on the same voice sample.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
