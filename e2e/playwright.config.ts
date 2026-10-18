import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  outputDir: './test-results',
  // 競技サーバへの負荷とテスト間の干渉を抑えるため、直列で回す
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 240_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never', outputFolder: './playwright-report' }]],
  use: {
    // ISUCON の TLS 証明書は /etc/hosts で向け先を変えた環境だと検証に通らないことがある
    ignoreHTTPSErrors: true,
    locale: 'ja-JP',
    timezoneId: 'Asia/Tokyo',
    viewport: { width: 1280, height: 800 },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    // マルチスレッドのラスタライズは角丸などのアンチエイリアスが実行ごとに 1 ずれ、
    // 同じ画面でも PNG が変わって git の差分ノイズになるため、単一スレッドに固定する
    launchOptions: { args: ['--num-raster-threads=1', '--disable-partial-raster', '--disable-skia-runtime-opts'] },
  },
})
