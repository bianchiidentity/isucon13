import { test as base, expect, Page } from '@playwright/test'
import path from 'node:path'

// 接続先。競技環境が変わっても E2E_*_URL で上書きできるようにしておく
// __TARGETS__ はスキルが生成時に実際のホストへ置き換える
export const targets = {
  pipe: process.env.E2E_PIPE_URL ?? 'https://pipe.u.isucon.local',
  // ユーザーごとのサブドメイン。/user がそのユーザーのページになる
  test001: process.env.E2E_USER_URL ?? 'https://test001.u.isucon.local',
}

// 初期データの検証用ユーザ（webapp/sql/initial_users.sql の NOTE: パスワードは `test`）
export const account = { username: 'test001', password: 'test' }

// 初期実装の statistics API は並列で叩くと 1 本 40〜60 秒かかる。統計値を待つアサーションだけこの値を使う
export const SLOW = 150_000

/**
 * API でログインする。UI ログインだと遷移先のトップで statistics が 10 本飛び、
 * HTTP/1.1 の接続枠（1 ホスト 6 本）が埋まって次の page.goto が数十秒詰まるため、UI ログインは専用のテスト 1 本だけにしている。
 * page.request はブラウザコンテキストと Cookie を共有する
 */
export async function apiLogin(page: Page) {
  const res = await page.request.post(targets.pipe + '/api/login', { data: account })
  expect(res.status(), 'POST /api/login').toBe(200)
}

type Problems = {
  /** テスト中に許容するエラー（正規表現）。意図的に 4xx を踏むテストで使う */
  allowProblems: (re: RegExp) => void
}

/**
 * 全テスト共通の監視:
 * - JS の例外 (pageerror) と console.error
 * - 自オリジンへのリクエストの 4xx/5xx・通信失敗
 * をテスト終了時にまとめて検査する。画面が「見た目上は出ているが裏で壊れている」状態を拾うため。
 */
export const test = base.extend<Problems>({
  allowProblems: [
    async ({ page }, use, testInfo) => {
      const problems: string[] = []
      const allowed: RegExp[] = []
      const hosts = new Set(Object.values(targets).map((u) => new URL(u).host))
      const isOwn = (url: string) => {
        try {
          return hosts.has(new URL(url).host)
        } catch {
          return false
        }
      }

      page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`))
      page.on('console', (m) => {
        if (m.type() === 'error') problems.push(`console.error: ${m.text()}`)
      })
      page.on('response', (r) => {
        if (isOwn(r.url()) && r.status() >= 400) problems.push(`HTTP ${r.status()}: ${r.request().method()} ${r.url()}`)
      })
      page.on('requestfailed', (r) => {
        // 画面遷移やテスト終了で打ち切られた遅い API（statistics など）は不具合ではないので数えない
        if (r.failure()?.errorText === 'net::ERR_ABORTED') return
        if (isOwn(r.url())) problems.push(`requestfailed: ${r.method()} ${r.url()} ${r.failure()?.errorText ?? ''}`)
      })
      // window.alert はエラー通知に使われがち。テストが止まらないよう閉じつつ記録する
      page.on('dialog', async (d) => {
        problems.push(`dialog(${d.type()}): ${d.message()}`)
        await d.dismiss()
      })

      await use((re) => allowed.push(re))

      const unexpected = problems.filter((p) => !allowed.some((re) => re.test(p)))
      if (unexpected.length) {
        await testInfo.attach('problems', { body: unexpected.join('\n'), contentType: 'text/plain' })
      }
      expect(unexpected, 'ページ表示中に JS エラー / HTTP エラー / alert が発生した').toEqual([])
    },
    { auto: true },
  ],
})

export { expect }
export type { Page }

const SCREENSHOT_DIR = path.join(__dirname, '..', 'screenshots')
// 数千行のテーブルをフルページで撮ると 10MB を超え、git に載せられなくなるため上限を設ける
const MAX_HEIGHT = 4000

/**
 * 目視用のスクリーンショットを screenshots/<name>.png に保存する（ページ全体、ただし高さは MAX_HEIGHT まで）。
 * 比較はしない（判定はアサーションで行う）。git にコミットしておけば `git status` で差分のある画面がわかる。
 * 呼ぶ前に、データ読み込み完了を示す要素を expect で待っておくこと。
 */
export async function snap(page: Page, name: string) {
  // アニメーションやキャレットで毎回ピクセルが変わらないようにする
  await page.addStyleTag({
    content: '*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }',
  })
  // 直前のクリック位置にカーソルが残ると、その下の要素のホバー表示が揺れて画像が変わる
  await page.mouse.move(0, 0)
  // fullPage 撮影だと position:fixed や 100vh の背景が最初の 1 画面分しか描かれず、下が白くなる。
  // ビューポート自体をページの高さまで広げて撮り、終わったら戻す
  // Web フォント適用前に測ると行の高さが変わり、実行ごとに画像の高さがずれる
  const original = page.viewportSize()!
  const height = await page.evaluate(async () => {
    await document.fonts.ready
    return document.documentElement.scrollHeight
  })
  await page.setViewportSize({ width: original.width, height: Math.min(Math.max(height, original.height), MAX_HEIGHT) })
  await page.screenshot({ path: path.join(SCREENSHOT_DIR, `${name}.png`) })
  await page.setViewportSize(original)
}
