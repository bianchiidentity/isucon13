import { test, expect, snap, targets, apiLogin, SLOW, Page } from './fixtures'

// 初期データで test001 が持つ配信。test001 は検証用ユーザでベンチは使わないので、タイトル・説明・NG ワードは変わらない
const LIVE = {
  id: 999,
  title: '映画レビュー！最新映画の感想を語る',
  description: '最新の映画について、感想や考察を深く掘り下げて話していきます。',
  ngword: '精神鍛錬術',
}

/**
 * 視聴ページと配信管理ページは、開くと POST /api/livestream/:id/enter で視聴履歴を INSERT し、
 * アンマウント時に DELETE .../exit で消す。タブを閉じるだけでは exit が飛ばず「視聴中」の人数が増え続けるので、
 * SPA 内のリンク（ヘッダのロゴ）で画面を離れて exit を確実に発火させる
 */
/** 動画は外部のメディアサーバから再生され、再生位置で毎回スクショが変わるので、止めて隠してから撮る */
async function hideVideo(page: Page) {
  await page.locator('video').evaluateAll((vs) =>
    vs.forEach((v) => {
      ;(v as HTMLVideoElement).pause()
      ;(v as HTMLVideoElement).style.visibility = 'hidden'
    }),
  )
}

async function leaveLivestream(page: Page, id: number) {
  const exit = page.waitForResponse((r) => r.request().method() === 'DELETE' && r.url().endsWith(`/api/livestream/${id}/exit`))
  // ヘッダのロゴ（react-router の Link）。サイドバーの「ホーム」はこれらのページには無い
  await page.getByRole('link', { name: 'ISUPipe' }).click()
  expect((await exit).status()).toBe(200)
}

test.describe('streamer (test001 でログイン)', () => {
  test.beforeEach(async ({ page }) => {
    await apiLogin(page)
  })

  test('トップ: 配信中の一覧', async ({ page }) => {
    await page.goto(targets.pipe + '/', { waitUntil: 'commit' })
    await expect(page.getByRole('button', { name: 'test001' })).toBeVisible()
    await expect(page.getByText('配信中', { exact: true })).toBeVisible()
    // 新しい配信順なので中身はベンチで変わる。カードが出ることだけを見る
    await expect(page.getByText(/人視聴・/).first()).toBeVisible()
    await expect(page.getByText('ログインが必要です')).toHaveCount(0)
    await snap(page, 'pipe-streamer-top')
  })

  test('検索: タグ DIY', async ({ page }) => {
    await page.goto(targets.pipe + '/search?q=DIY', { waitUntil: 'commit' })
    await expect(page.getByText('検索結果 DIY')).toBeVisible()
    await expect(page.getByText(/人視聴・/).first()).toBeVisible()
    await snap(page, 'pipe-streamer-search')
  })

  test('配信管理: 自分の配信一覧', async ({ page }) => {
    await page.goto(targets.pipe + '/console', { waitUntil: 'commit' })
    await expect(page.getByText('配信一覧')).toBeVisible()
    await expect(page.getByText(LIVE.title).first()).toBeVisible()
    await expect(page.getByRole('button', { name: '予約配信を作成' })).toBeVisible()
    await snap(page, 'pipe-streamer-console')
  })

  test('配信管理: 予約配信の作成モーダルを開いて閉じる（作成はしない）', async ({ page }) => {
    await page.goto(targets.pipe + '/console', { waitUntil: 'commit' })
    await page.getByRole('button', { name: '予約配信を作成' }).click()
    const dialog = page.getByRole('dialog')
    await expect(dialog.getByText('予約配信の作成')).toBeVisible()
    await expect(dialog.getByText('タイトル')).toBeVisible()
    await expect(dialog.getByText('説明文')).toBeVisible()
    await expect(dialog.getByRole('button', { name: '作成' })).toBeVisible()
    await snap(page, 'pipe-streamer-console-reserve-modal')
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
  })

  test('配信管理: 配信詳細（NG ワード・通報）', async ({ page }) => {
    await page.goto(targets.pipe + `/console/live/${LIVE.id}`, { waitUntil: 'commit' })
    await expect(page.getByText(LIVE.title)).toBeVisible()
    await expect(page.getByText(LIVE.description)).toBeVisible()
    await expect(page.getByText('NG Word')).toBeVisible()
    await expect(page.getByText(LIVE.ngword)).toBeVisible()
    await expect(page.getByText('通報されたコメント')).toBeVisible()
    await hideVideo(page)
    await snap(page, 'pipe-streamer-console-live')
    await leaveLivestream(page, LIVE.id)
  })

  test('視聴: 自分の配信', async ({ page }) => {
    await page.goto(targets.pipe + `/watch/${LIVE.id}`, { waitUntil: 'commit' })
    await expect(page.getByText(LIVE.title).first()).toBeVisible()
    await expect(page.getByText(LIVE.description)).toBeVisible()
    await expect(page.getByText('検証用ユーザ')).toBeVisible()
    await expect(page.getByText('Related Live')).toBeVisible()
    await expect(page.getByRole('button', { name: '送信' })).toBeVisible()
    // 関連配信は配信のタグで検索して出す（中身はベンチで変わるので、カードが出ることだけを見る）
    await expect(page.getByText(/人視聴・/).first()).toBeVisible()
    await hideVideo(page)
    await snap(page, 'pipe-streamer-watch')
    // 関連配信が出ると約 100 本の statistics が HTTP/1.1 の接続枠（1 ホスト 6 本）を埋め、
    // 画面遷移で出る DELETE /exit が数分待たされる。後片付けはブラウザと別の接続を持つ page.request で行う（Cookie は共有）
    const exit = await page.request.delete(targets.pipe + `/api/livestream/${LIVE.id}/exit`)
    expect(exit.status(), 'DELETE /exit').toBe(200)
  })

  test('ユーザーページ: プロフィールと統計', async ({ page }) => {
    await page.goto(targets.test001 + '/user', { waitUntil: 'commit' })
    await expect(page.getByText('社内検証用')).toBeVisible()
    await expect(page.getByText(LIVE.title).first()).toBeVisible()
    // 統計の値はベンチのコメント・リアクションで変わるので書式だけを見る。初期実装では 40 秒前後かかる
    await expect(page.getByText(/^ランキング\s*\d+位$/)).toBeVisible({ timeout: SLOW })
    await expect(page.getByText(/^コメント数\s*\d+$/)).toBeVisible()
    await expect(page.getByText(/^Tip数\s*\d+ISU$/)).toBeVisible()
    await snap(page, 'test001-streamer-user')
  })

  test('ユーザーページ: アイコン変更モーダルを開いて閉じる（変更はしない）', async ({ page }) => {
    await page.goto(targets.test001 + '/user', { waitUntil: 'commit' })
    await page.getByRole('button', { name: '画像変更' }).click()
    const dialog = page.getByRole('dialog')
    await expect(dialog.getByRole('heading', { name: 'アイコン変更' })).toBeVisible()
    await expect(dialog.getByText('アイコン画像ファイル')).toBeVisible()
    await expect(dialog.getByRole('button', { name: '変更' })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
  })
})
