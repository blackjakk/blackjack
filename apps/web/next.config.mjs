/** @type {import('next').NextConfig} */
const nextConfig = {
    // Fully client-side app (all state comes from the chain), so it exports statically
    // and can be hosted anywhere — GitHub Pages serves it from /blackjack.
    output: "export",
    basePath: process.env.NEXT_PUBLIC_BASE_PATH ?? "",
    images: {unoptimized: true},
    transpilePackages: ["@blackjack/config", "@blackjack/sdk"],
};

export default nextConfig;
