import type { Metadata } from "next";
import "./globals.css";
import BottomMenu from '@/components/bottom-menu';
import Navbar from '@/components/navbar';



export const metadata: Metadata = {
  title: "Create Next App",
  description: "Generated by create next app",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`antialiased`}
      >
        <div className='mobile-container'>
          <Navbar />
          <div className="h-full py-5 items-center flex flex-col justify-center" style={{ transform: 'scale(0.98)'}}>
            {children}
          </div>
          <BottomMenu />
        </div>
      </body>
    </html>
  );
}