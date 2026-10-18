import { test, expect, snap, targets, account } from './fixtures'

// 未ログインでは、どのページもまず GET /api/user/me が 403 を返し、ブラウザが console.error に
// "Failed to load resource: ... 403" を出す。初期実装の正しい振る舞いなので、該当するテストに限って許可する
const ALLOW_ME_403 = /HTTP 403: GET https:\/\/[^/]+\/api\/user\/me$/
const ALLOW_RESOURCE_403 = /console\.error: Failed to load resource: the server responded with a status of 403/

test.describe('guest (未ログイン)', () => {
  test.beforeEach(async ({ allowProblems }) => {
    allowProblems(ALLOW_ME_403)
    allowProblems(ALLOW_RESOURCE_403)
  })

  test('トップ: ログインを促す表示と配信一覧', async ({ page, allowProblems }) => {
    // 未ログインでも配信カードの統計を取りに行き、403 になる
    allowProblems(/HTTP 403: GET https:\/\/[^/]+\/api\/livestream\/\d+\/statistics$/)
    await page.goto(targets.pipe + '/', { waitUntil: 'commit' })
    await expect(page.getByText('ログインが必要です')).toBeVisible()
    // 「ログインが必要です」のモーダルが背後を aria-hidden にするので、ロールではなく文言で見る
    await expect(page.getByText('未ログイン')).toBeVisible()
    await expect(page.getByText('配信中', { exact: true })).toBeVisible()
    // 一覧の中身はベンチが予約した配信で入れ替わるので、カードが出ることだけを見る
    await expect(page.getByText(/人視聴・/).first()).toBeVisible()
    await snap(page, 'pipe-guest-top')
  })

  test('ログイン画面', async ({ page }) => {
    await page.goto(targets.pipe + '/account/login', { waitUntil: 'commit' })
    await expect(page.getByLabel('Username')).toBeVisible()
    await expect(page.getByLabel('Password')).toBeVisible()
    await expect(page.getByRole('button', { name: 'ログイン', exact: true })).toBeVisible()
    await expect(page.getByRole('link', { name: '新規登録' })).toHaveAttribute('href', '/account/signup')
    await snap(page, 'pipe-guest-login')
  })

  test('新規登録画面（送信はしない）', async ({ page }) => {
    await page.goto(targets.pipe + '/account/signup', { waitUntil: 'commit' })
    for (const label of ['Username', 'Description', 'Login ID', 'Password']) {
      await expect(page.getByLabel(label)).toBeVisible()
    }
    await expect(page.getByRole('button', { name: '登録' })).toBeVisible()
    await snap(page, 'pipe-guest-signup')
  })

  test('ログインフォームから test001 でログインできる', async ({ page }) => {
    await page.goto(targets.pipe + '/account/login', { waitUntil: 'commit' })
    await page.getByLabel('Username').fill(account.username)
    await page.getByLabel('Password').fill(account.password)
    await page.getByRole('button', { name: 'ログイン', exact: true }).click()
    await expect(page).toHaveURL(targets.pipe + '/')
    // ヘッダのメニューボタンが「未ログイン」からユーザー名に変わる
    await expect(page.getByRole('button', { name: account.username })).toBeVisible()
  })

  test('配信管理: 未ログインではログインを促す', async ({ page, allowProblems }) => {
    allowProblems(/HTTP 403: GET https:\/\/[^/]+\/api\/livestream$/)
    await page.goto(targets.pipe + '/console', { waitUntil: 'commit' })
    await expect(page.getByText('ログインが必要です')).toBeVisible()
    await expect(page.getByText('配信一覧')).toBeVisible()
    await snap(page, 'pipe-guest-console')
  })

  test('ユーザーページ: 未ログインではログインを促す', async ({ page, allowProblems }) => {
    allowProblems(/HTTP 403: GET https:\/\/test001\.[^/]+\/api\/user\/test001(\/statistics|\/livestream)?$/)
    await page.goto(targets.test001 + '/user', { waitUntil: 'commit' })
    await expect(page.getByText('ログインが必要です')).toBeVisible()
    await expect(page.getByText('好きな絵文字')).toBeVisible()
    await snap(page, 'test001-guest-user')
  })
})
