import path from "path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig, type Plugin } from "vite"
import { viteSingleFile } from "vite-plugin-singlefile"

const devMockPlugin = (): Plugin => {
  const mockUser = {
    id: 101,
    username: "mohammad_vip",
    status: "active",
    used_traffic: 28.4 * 1024 * 1024 * 1024,
    lifetime_used_traffic: 84.2 * 1024 * 1024 * 1024,
    data_limit: 80 * 1024 * 1024 * 1024,
    data_limit_reset_strategy: "no_reset",
    expire: new Date(Date.now() + 19 * 86400000).toISOString(),
    on_hold_expire_duration: null,
    on_hold_timeout: null,
    group_ids: [1],
    created_at: new Date(Date.now() - 30 * 86400000).toISOString(),
    edit_at: null,
    online_at: new Date(Date.now() - 3 * 60000).toISOString(),
    proxy_settings: {
      vmess: { id: "89a9f244-1234-4567-89ab-cdef01234567" },
      vless: { id: "89a9f244-1234-4567-89ab-cdef01234567", flow: "xtls-rprx-vision" },
      trojan: { password: "super_pass_123" },
      shadowsocks: { password: "mrm_pass_789", method: "chacha20-ietf-poly1305" }
    },
    next_plan: null
  };

  const mockLinks = [
    "vless://89a9f244-1234-4567-89ab-cdef01234567@de.mrm-server.net:443?security=reality&type=tcp&sni=speedtest.net&fp=chrome&pbk=1234567890abcdefghijklmnopqrstuvwxyz123456&sid=12345678#%F0%9F%87%A9%F0%9F%87%AA%20DE%20%7C%20Frankfurt%20-%20Reality%20VIP",
    "vmess://eyJhZGQiOiJmaS5tcm0tc2VydmVyLm5ldCIsImFpZCI6MCwiaG9zdCI6ImZpLm1ybS1zZXJ2ZXIubmV0IiwiaWQiOiI4OWE5ZjI0NC0xMjM0LTQ1NjctODlhYi1jZGVmMDEyMzQ1NjciLCJuZXQiOiJ3cyIsInBhdGgiOiIvdjIiLCJwcyI6IvCfh0bwn4e4IEZJICB8IEhlbHNpbmtpIC0gV1MgVklQIiwic2N5IjoiYXV0byIsInNuaSI6ImZpLm1ybS1zZXJ2ZXIubmV0IiwidGxzIjoidGxzIiwidHlwZSI6Im5vbmUifQ==",
    "trojan://super_pass_123@nl.mrm-server.net:443?security=tls&sni=nl.mrm-server.net&type=ws&path=%2Ftrojan#%F0%9F%87%B3%F0%9F%87%B1%20NL%20%7C%20Amsterdam%20-%20Fast%20Trojan",
    "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTptcm1fcGFzc183ODk=@fr.mrm-server.net:8443#%F0%9F%87%AB%F0%9F%87%B7%20FR%20%7C%20Paris%20-%20Shadowsocks%20TCP"
  ];

  const mockApps = [
    {
      name: "v2rayNG",
      icon_url: "https://raw.githubusercontent.com/2dust/v2rayNG/master/V2rayNG/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
      import_url: "v2rayng://install-sub?url={url}&name={name}",
      description: "کلاینت استاندارد و پرقدرت اندروید",
      recommended: true,
      platform: "android",
      download_links: [
        { name: "Google Play", url: "https://play.google.com/store/apps/details?id=com.v2ray.ang", language: "fa" },
        { name: "GitHub", url: "https://github.com/2dust/v2rayNG/releases", language: "en" }
      ]
    },
    {
      name: "Streisand",
      icon_url: "",
      import_url: "streisand://import/{url}",
      description: "کلاینت سبک، مدرن و سریع برای iOS",
      recommended: true,
      platform: "ios",
      download_links: [
        { name: "App Store", url: "https://apps.apple.com/app/id6450534064", language: "en" }
      ]
    },
    {
      name: "Hiddify",
      icon_url: "",
      import_url: "hiddify://import/{url}",
      description: "اپلیکیشن چندسکویی مدرن با رابط کاربری روان",
      recommended: false,
      platform: "all",
      download_links: [
        { name: "App Store", url: "https://apps.apple.com/app/id6596777532", language: "en" },
        { name: "Google Play", url: "https://play.google.com/store/apps/details?id=com.hiddify.app", language: "en" }
      ]
    }
  ];

  const generateChartStats = () => {
    const stats = [];
    const now = Date.now();
    for (let i = 14; i >= 0; i--) {
      const dayStart = new Date(now - i * 86400000);
      dayStart.setHours(0, 0, 0, 0);
      const randomTraffic = Math.floor((1.2 + Math.sin(i * 0.8) * 0.9 + (i % 3 === 0 ? 1.5 : 0.5)) * 1024 * 1024 * 1024);
      stats.push({
        period_start: dayStart.toISOString(),
        total_traffic: randomTraffic
      });
    }
    return { stats: { default: stats } };
  };

  return {
    name: "dev-mock-plugin",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = req.url || "";
        if (url.endsWith("/info")) {
          res.setHeader("Content-Type", "application/json");
          res.setHeader("announce", encodeURIComponent("💡 سرورهای آلمان و فنلاند با پروتکل فوق‌سریع Reality فعال هستند."));
          res.setHeader("support-url", "https://t.me/PasarGuardSupport");
          res.end(JSON.stringify(mockUser));
          return;
        }
        if (url.endsWith("/raw")) {
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ links: mockLinks }));
          return;
        }
        if (url.endsWith("/apps")) {
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify(mockApps));
          return;
        }
        if (url.includes("/usage")) {
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify(generateChartStats()));
          return;
        }
        next();
      });
    },
    transformIndexHtml(html) {
      // In dev mode, replace Jinja template variables with realistic mock JSON
      return html
        .replace(/__BRAND__/g, "MRM Special")
        .replace(
          /user:\s*\{% if user %\}[\s\S]*?\{% else %\}null\{% endif %\}/,
          `user: ${JSON.stringify(mockUser)}`
        )
        .replace(
          /links:\s*\{\{\s*links\s*\|\s*tojson\s*\|\s*safe\s*\}\}/,
          `links: ${JSON.stringify(mockLinks)}`
        )
        .replace(
          /apps:\s*\{% if apps %\}[\s\S]*?\{% else %\}null\{% endif %\}/,
          `apps: ${JSON.stringify(mockApps)}`
        )
        .replace(/\{\{\s*user\.username\s*\}\}/g, mockUser.username);
    }
  };
};

export default defineConfig(({ command }) => ({
  plugins: [
    ...(command === "serve" ? [devMockPlugin()] : []),
    react(), 
    tailwindcss(), 
    viteSingleFile()
  ],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    target: 'es2020',
    chunkSizeWarningLimit: 1000,
    sourcemap: false,
    minify: true
  },
  esbuild: {
    drop: ['console', 'debugger']
  },
  optimizeDeps: {
    include: [
      'react',
      'react-dom',
      'react-i18next',
      'i18next',
      'swr',
      'recharts'
    ]
  },
  server: {
    host: '0.0.0.0',
    port: 5173,
    allowedHosts: true,
    fs: {
      allow: ['..']
    }
  }
}))
