import "./globals.css";

export const metadata = { title: "Looktok Admin" };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body className="bg-[#F7F7F5] text-[#0A0A0A] antialiased">{children}</body>
    </html>
  );
}
