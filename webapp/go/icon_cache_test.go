package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo/v4"
)

func newMockTx(t *testing.T) (*sqlx.Tx, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	mock.ExpectBegin()
	tx, err := sqlx.NewDb(db, "sqlmock").Beginx()
	if err != nil {
		t.Fatal(err)
	}
	return tx, mock
}

func TestIconHashCache(t *testing.T) {
	resetIconCache()
	tx, mock := newMockTx(t)
	ctx := context.Background()

	// 無ければ DB から読み、2 回目は DB を読まない
	mock.ExpectQuery("SELECT image FROM icons WHERE user_id = ?").WithArgs(int64(1)).WillReturnRows(sqlmock.NewRows([]string{"image"}).AddRow([]byte("old")))
	for i := 0; i < 2; i++ {
		got, err := getIconHash(ctx, tx, 1)
		if err != nil {
			t.Fatal(err)
		}
		if got != calcIconHash([]byte("old")) {
			t.Fatalf("got %s", got)
		}
	}

	// 更新は上書きし、古いスナップショットから読んだ値では上書きされない
	setIconHash(1, []byte("new"))
	if got := loadOrStoreIconHash(1, calcIconHash([]byte("old"))); got != calcIconHash([]byte("new")) {
		t.Fatalf("stale value overwrote: %s", got)
	}

	// アイコンが無いユーザーは NoImage のハッシュ
	mock.ExpectQuery("SELECT image FROM icons WHERE user_id = ?").WithArgs(int64(2)).WillReturnRows(sqlmock.NewRows([]string{"image"}))
	fallback, err := os.ReadFile(fallbackImage)
	if err != nil {
		t.Fatal(err)
	}
	got, err := getIconHash(ctx, tx, 2)
	if err != nil {
		t.Fatal(err)
	}
	if got != calcIconHash(fallback) {
		t.Fatalf("got %s", got)
	}

	// リセット後は再び DB を読む
	resetIconCache()
	if _, ok := loadIconHash(1); ok {
		t.Fatal("cache not reset")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestIconHashesBatchReadsOnlyMissing(t *testing.T) {
	resetIconCache()
	tx, mock := newMockTx(t)
	setIconHash(1, []byte("cached"))
	fallback, err := os.ReadFile(fallbackImage)
	if err != nil {
		t.Fatal(err)
	}

	// 同じユーザーの行が複数あれば、id の小さい方を使う（ORDER BY id の先頭）
	mock.ExpectQuery("SELECT user_id, image FROM icons WHERE user_id IN").WithArgs(int64(2), int64(3)).
		WillReturnRows(sqlmock.NewRows([]string{"user_id", "image"}).AddRow(2, []byte("two")).AddRow(2, []byte("later")))
	got, err := getIconHashes(context.Background(), tx, []int64{1, 2, 3})
	if err != nil {
		t.Fatal(err)
	}
	want := map[int64]string{1: calcIconHash([]byte("cached")), 2: calcIconHash([]byte("two")), 3: calcIconHash(fallback)}
	for id, hash := range want {
		if got[id] != hash {
			t.Fatalf("user %d: got %s; want %s", id, got[id], hash)
		}
	}

	// 全員キャッシュにあればクエリを投げない
	if _, err := getIconHashes(context.Background(), tx, []int64{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestIfNoneMatchHas(t *testing.T) {
	cases := []struct {
		header string
		want   bool
	}{
		{`"abc"`, true},
		{` "abc" `, true},
		{`W/"abc"`, true},
		{`"x", "abc"`, true},
		{`"x",W/"abc"`, true},
		{`"x", "y"`, false},
		{`abc`, false},
		{`"abcd"`, false},
		{`*`, false},
	}
	for _, tc := range cases {
		if got := ifNoneMatchHas(tc.header, "abc"); got != tc.want {
			t.Errorf("%q: got %v; want %v", tc.header, got, tc.want)
		}
	}
}

func TestGetIconConditional(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	orig := dbConn
	dbConn = sqlx.NewDb(db, "sqlmock")
	defer func() { dbConn = orig }()

	fallback, err := os.ReadFile(fallbackImage)
	if err != nil {
		t.Fatal(err)
	}
	hash := calcIconHash([]byte("image"))
	fallbackHash := calcIconHash(fallback)

	cases := []struct {
		name        string
		hasIcon     bool
		cached      bool
		ifNoneMatch []string
		wantStatus  int
		wantBody    string
		wantETag    string
	}{
		{"match", true, true, []string{`"` + hash + `"`}, http.StatusNotModified, "", `"` + hash + `"`},
		{"match among candidates", true, true, []string{`"deadbeef", W/"` + hash + `"`}, http.StatusNotModified, "", `"` + hash + `"`},
		{"match in second header line", true, true, []string{`"deadbeef"`, `"` + hash + `"`}, http.StatusNotModified, "", `"` + hash + `"`},
		{"mismatch", true, true, []string{`"deadbeef"`}, http.StatusOK, "image", `"` + hash + `"`},
		{"wildcard", true, true, []string{`*`}, http.StatusOK, "image", `"` + hash + `"`},
		{"unconditional", true, true, nil, http.StatusOK, "image", `"` + hash + `"`},
		// 更新直後でキャッシュが古くても、200 の ETag は返す本文と一致する
		{"stale cache", true, false, nil, http.StatusOK, "image", `"` + hash + `"`},
		{"fallback match", false, false, []string{`"` + fallbackHash + `"`}, http.StatusNotModified, "", `"` + fallbackHash + `"`},
		{"fallback unconditional", false, false, nil, http.StatusOK, string(fallback), `"` + fallbackHash + `"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resetIconCache()
			if tc.cached {
				setIconHash(7, []byte("image"))
			} else if tc.hasIcon {
				setIconHash(7, []byte("old image"))
			}
			mock.ExpectBegin()
			mock.ExpectQuery("SELECT \\* FROM users WHERE name = ?").WithArgs("alice").
				WillReturnRows(sqlmock.NewRows([]string{"id", "name", "display_name", "description", "password"}).AddRow(7, "alice", "Alice", "", "x"))
			if !tc.hasIcon {
				// キャッシュに無いので、304 の判定と 200 の本文でそれぞれ icons を読む
				queries := 1
				if tc.ifNoneMatch != nil && tc.wantStatus == http.StatusOK {
					queries = 2
				}
				for i := 0; i < queries; i++ {
					mock.ExpectQuery("SELECT image FROM icons WHERE user_id = ?").WithArgs(int64(7)).WillReturnRows(sqlmock.NewRows([]string{"image"}))
				}
			} else if tc.wantStatus == http.StatusOK {
				mock.ExpectQuery("SELECT image FROM icons WHERE user_id = ?").WithArgs(int64(7)).WillReturnRows(sqlmock.NewRows([]string{"image"}).AddRow([]byte("image")))
			}
			mock.ExpectRollback()

			e := echo.New()
			req := httptest.NewRequest(http.MethodGet, "/api/user/alice/icon", nil)
			for _, v := range tc.ifNoneMatch {
				req.Header.Add("If-None-Match", v)
			}
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)
			c.SetParamNames("username")
			c.SetParamValues("alice")
			if err := getIconHandler(c); err != nil {
				t.Fatal(err)
			}
			if rec.Code != tc.wantStatus {
				t.Fatalf("got %d; want %d", rec.Code, tc.wantStatus)
			}
			if rec.Body.String() != tc.wantBody {
				t.Fatalf("body length %d; want %d", rec.Body.Len(), len(tc.wantBody))
			}
			if got := rec.Header().Get("ETag"); got != tc.wantETag {
				t.Fatalf("ETag %s; want %s", got, tc.wantETag)
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestGetIconUnknownUser(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	orig := dbConn
	dbConn = sqlx.NewDb(db, "sqlmock")
	defer func() { dbConn = orig }()

	mock.ExpectBegin()
	mock.ExpectQuery("SELECT \\* FROM users WHERE name = ?").WithArgs("nobody").WillReturnRows(sqlmock.NewRows([]string{"id"}))
	mock.ExpectRollback()
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/api/user/nobody/icon", nil)
	req.Header.Set("If-None-Match", `"abc"`)
	c := e.NewContext(req, httptest.NewRecorder())
	c.SetParamNames("username")
	c.SetParamValues("nobody")
	err = getIconHandler(c)
	he, ok := err.(*echo.HTTPError)
	if !ok || he.Code != http.StatusNotFound {
		t.Fatalf("got %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
