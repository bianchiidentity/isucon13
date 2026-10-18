package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
	"github.com/gorilla/sessions"
	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo-contrib/session"
	"github.com/labstack/echo/v4"
)

// 明示的に指定した使い捨て DB のみ利用する。通常の go test は外部 DB 不要。
func performanceDB(t *testing.T) *sqlx.DB {
	t.Helper()
	dsn := os.Getenv("ISUCON_PERF_TEST_DSN")
	if dsn == "" {
		t.Skip("ISUCON_PERF_TEST_DSN is not set")
	}
	config, err := mysql.ParseDSN(dsn)
	if err != nil || !strings.HasSuffix(config.DBName, "_perf_test") {
		t.Fatal("dedicated database ending in _perf_test required")
	}
	db, err := sqlx.Connect("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	dbConn = db
	tables := []string{"livecomment_reports", "livecomments", "reactions", "livestream_viewers_history", "livestream_tags", "ng_words", "reservation_slots", "livestreams", "themes", "icons", "users", "tags"}
	clean := func() {
		for _, table := range tables {
			db.MustExec("DELETE FROM " + table)
		}
		resetIconCache()
	}
	clean()
	t.Cleanup(clean)
	db.MustExec(`INSERT INTO users(id,name,display_name,password,description) VALUES
 (1,'owner','Owner','secret','bio'),(2,'viewer','Viewer','secret',''),(3,'empty','Empty','secret','')`)
	db.MustExec(`INSERT INTO themes(id,user_id,dark_mode) VALUES (1,1,1),(2,2,0),(3,3,0)`)
	db.MustExec(`INSERT INTO icons(user_id,image) VALUES (1,?), (2,?)`, []byte("owner image"), []byte{})
	db.MustExec(`INSERT INTO livestreams(id,user_id,title,description,playlist_url,thumbnail_url,start_at,end_at) VALUES
 (10,1,'ten','desc','pl','thumb',1,2),(20,1,'twenty','desc','pl','thumb',3,4),(30,2,'thirty','desc','pl','thumb',5,6)`)
	db.MustExec(`INSERT INTO tags(id,name) VALUES (1,'tag'),(2,'other')`)
	db.MustExec(`INSERT INTO livestream_tags(id,livestream_id,tag_id) VALUES (1,10,2),(2,10,1),(3,10,1),(4,20,1)`)
	db.MustExec(`INSERT INTO livecomments(id,user_id,livestream_id,comment,tip,created_at) VALUES
 (1,2,10,'first',100,1),(2,2,10,'second',0,2),(3,1,20,'third',200,3),(4,3,10,'fallback',50,2),(5,2,30,'other',999,1)`)
	db.MustExec(`INSERT INTO reactions(id,user_id,livestream_id,emoji_name,created_at) VALUES
 (1,2,10,'a',1),(2,2,10,'b',2),(3,1,20,'a',3),(4,3,10,'a',2)`)
	db.MustExec(`INSERT INTO livecomment_reports(id,user_id,livestream_id,livecomment_id,created_at) VALUES
 (1,1,10,1,1),(2,2,10,1,2),(3,1,10,4,3)`)
	db.MustExec(`INSERT INTO livestream_viewers_history(user_id,livestream_id,created_at) VALUES (1,10,1),(1,10,2),(2,20,3),(3,30,4)`)
	return db
}

func performanceRequest(handler echo.HandlerFunc, route, path, method, body string, userID int64) *httptest.ResponseRecorder {
	e := echo.New()
	e.Use(session.Middleware(sessions.NewCookieStore(secret)))
	e.Use(func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			sess, err := session.Get(defaultSessionIDKey, c)
			if err != nil {
				return err
			}
			sess.Values[defaultUserIDKey] = userID
			sess.Values[defaultSessionExpiresKey] = time.Now().Add(time.Hour).Unix()
			return next(c)
		}
	})
	e.Add(method, route, handler)
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	recorder := httptest.NewRecorder()
	e.ServeHTTP(recorder, request)
	return recorder
}

func TestPerformanceResponsesMySQL(t *testing.T) {
	db := performanceDB(t)
	pairs := []struct {
		route, path string
		old, new    echo.HandlerFunc
	}{
		{"/api/livestream/search", "/api/livestream/search", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream/search", "/api/livestream/search?limit=2", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream/search", "/api/livestream/search?limit=0", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream/search", "/api/livestream/search?limit=bad", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream/search", "/api/livestream/search?limit=-1", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream/search", "/api/livestream/search?tag=tag&limit=1", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream/search", "/api/livestream/search?tag=missing", legacySearchLivestreamsHandler, searchLivestreamsHandler},
		{"/api/livestream", "/api/livestream", legacyGetMyLivestreamsHandler, getMyLivestreamsHandler},
		{"/api/user/:username/livestream", "/api/user/owner/livestream", legacyGetUserLivestreamsHandler, getUserLivestreamsHandler},
		{"/api/user/:username/livestream", "/api/user/empty/livestream", legacyGetUserLivestreamsHandler, getUserLivestreamsHandler},
		{"/api/livestream/:livestream_id/livecomment", "/api/livestream/10/livecomment", legacyGetLivecommentsHandler, getLivecommentsHandler},
		{"/api/livestream/:livestream_id/livecomment", "/api/livestream/10/livecomment?limit=1", legacyGetLivecommentsHandler, getLivecommentsHandler},
		{"/api/livestream/:livestream_id/livecomment", "/api/livestream/99/livecomment", legacyGetLivecommentsHandler, getLivecommentsHandler},
		{"/api/livestream/:livestream_id/reaction", "/api/livestream/10/reaction", legacyGetReactionsHandler, getReactionsHandler},
		{"/api/livestream/:livestream_id/reaction", "/api/livestream/10/reaction?limit=1", legacyGetReactionsHandler, getReactionsHandler},
		{"/api/livestream/:livestream_id/reaction", "/api/livestream/99/reaction", legacyGetReactionsHandler, getReactionsHandler},
		{"/api/livestream/:livestream_id/report", "/api/livestream/10/report", legacyGetLivecommentReportsHandler, getLivecommentReportsHandler},
		{"/api/user/:username/statistics", "/api/user/owner/statistics", legacyGetUserStatisticsHandler, getUserStatisticsHandler},
		{"/api/user/:username/statistics", "/api/user/empty/statistics", legacyGetUserStatisticsHandler, getUserStatisticsHandler},
	}
	for _, pair := range pairs {
		t.Run(pair.path, func(t *testing.T) {
			old := performanceRequest(pair.old, pair.route, pair.path, http.MethodGet, "", 1)
			new := performanceRequest(pair.new, pair.route, pair.path, http.MethodGet, "", 1)
			var before, after interface{}
			if err := json.Unmarshal(old.Body.Bytes(), &before); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(new.Body.Bytes(), &after); err != nil {
				t.Fatal(err)
			}
			if old.Code != new.Code || !reflect.DeepEqual(before, after) {
				t.Fatalf("old %d %s\nnew %d %s", old.Code, old.Body.String(), new.Code, new.Body.String())
			}
		})
	}
	// 検索単独の SELECT 回数: 件数を増やしても一括取得の回数が増えない。
	tx := db.MustBegin()
	defer tx.Rollback()
	count := func() int {
		var rows []struct {
			Name  string `db:"Variable_name"`
			Value int    `db:"Value"`
		}
		if err := tx.Select(&rows, "SHOW SESSION STATUS LIKE 'Com_select'"); err != nil {
			t.Fatal(err)
		}
		return rows[0].Value
	}
	var models []*LivestreamModel
	if err := tx.Select(&models, "SELECT * FROM livestreams ORDER BY id"); err != nil {
		t.Fatal(err)
	}
	before := count()
	if _, err := fillLivestreamResponses(context.Background(), tx, models[:1]); err != nil {
		t.Fatal(err)
	}
	small := count() - before
	large := append(append([]*LivestreamModel{}, models...), models...)
	before = count()
	if _, err := fillLivestreamResponses(context.Background(), tx, large); err != nil {
		t.Fatal(err)
	}
	big := count() - before
	if small != 5 || big != 5 {
		t.Fatalf("batch select count: small %d large %d", small, big)
	}
	t.Logf("response SQL count: 1 stream=%d, 6 streams=%d", small, big)
	var comments []LivecommentModel
	if err := tx.Select(&comments, "SELECT * FROM livecomments WHERE livestream_id=10 ORDER BY id"); err != nil {
		t.Fatal(err)
	}
	var reactions []ReactionModel
	if err := tx.Select(&reactions, "SELECT * FROM reactions WHERE livestream_id=10 ORDER BY id"); err != nil {
		t.Fatal(err)
	}
	var reports []*LivecommentReportModel
	if err := tx.Select(&reports, "SELECT * FROM livecomment_reports WHERE livestream_id=10 ORDER BY id"); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name          string
		batch, legacy func(int) error
	}{
		{"comments", func(n int) error {
			rows := make([]LivecommentModel, n)
			for i := range rows {
				rows[i] = comments[i%len(comments)]
			}
			_, err := fillLivecommentResponses(context.Background(), tx, rows)
			return err
		},
			func(n int) error {
				for i := 0; i < n; i++ {
					if _, err := legacyFillLivecommentResponse(context.Background(), tx, comments[i%len(comments)]); err != nil {
						return err
					}
				}
				return nil
			}},
		{"reactions", func(n int) error {
			rows := make([]ReactionModel, n)
			for i := range rows {
				rows[i] = reactions[i%len(reactions)]
			}
			_, err := fillReactionResponses(context.Background(), tx, rows)
			return err
		},
			func(n int) error {
				for i := 0; i < n; i++ {
					if _, err := legacyFillReactionResponse(context.Background(), tx, reactions[i%len(reactions)]); err != nil {
						return err
					}
				}
				return nil
			}},
		{"reports", func(n int) error {
			rows := make([]*LivecommentReportModel, n)
			for i := range rows {
				rows[i] = reports[i%len(reports)]
			}
			_, err := fillReportResponses(context.Background(), tx, rows)
			return err
		},
			func(n int) error {
				for i := 0; i < n; i++ {
					if _, err := legacyFillLivecommentReportResponse(context.Background(), tx, *reports[i%len(reports)]); err != nil {
						return err
					}
				}
				return nil
			}},
	} {
		before := count()
		if err := test.batch(1); err != nil {
			t.Fatal(err)
		}
		small := count() - before
		before = count()
		if err := test.batch(12); err != nil {
			t.Fatal(err)
		}
		large := count() - before
		before = count()
		if err := test.legacy(12); err != nil {
			t.Fatal(err)
		}
		old := count() - before
		if small != large || large >= old {
			t.Fatalf("%s: batch1=%d batch12=%d legacy12=%d", test.name, small, large, old)
		}
		t.Logf("%s SQL count: 12 rows legacy=%d batch=%d (1 row=%d)", test.name, old, large, small)
	}

}

func TestNGWordBatchMySQL(t *testing.T) {
	db := performanceDB(t)
	tx := db.MustBegin()
	defer tx.Rollback()
	comments := []LivecommentModel{}
	for i, text := range []string{"ABC", "abc", "日本語", "prefix_bad_suffix", "a_b", "a%b", `a\b`, "", "😀", "é", "e", "trailing "} {
		comments = append(comments, LivecommentModel{ID: int64(i + 1), Comment: text})
	}
	// 128件の境界と重複 ID を含める。
	for i := 0; i < 130; i++ {
		comments = append(comments, LivecommentModel{ID: int64(i + 100), Comment: "boundary"})
	}
	for _, pattern := range []string{"abc", "日本", "bad", "_", "%", `\`, `\_`, `\%`, "", "😀", "é", "e", "trailing"} {
		words := []*NGWord{{Word: pattern}, {Word: "never-match"}}
		want := []int64{}
		for _, comment := range comments {
			var hit int
			if err := tx.Get(&hit, `SELECT COUNT(*) FROM (SELECT ? AS text) AS texts INNER JOIN (SELECT CONCAT('%', ?, '%') AS pattern) AS patterns ON texts.text LIKE patterns.pattern`, comment.Comment, pattern); err != nil {
				t.Fatal(err)
			}
			if hit > 0 {
				want = append(want, comment.ID)
			}
		}
		got, err := matchingCommentIDs(context.Background(), tx, comments, words)
		if err != nil {
			t.Fatal(err)
		}
		sort.Slice(got, func(i, j int) bool { return got[i] < got[j] })
		sort.Slice(want, func(i, j int) bool { return want[i] < want[j] })
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("pattern %q: got %v want %v", pattern, got, want)
		}
	}
	// NG語側のチャンク境界を越えた一致と、複数チャンクにまたがる重複一致。
	manyWords := make([]*NGWord, 130)
	for i := range manyWords {
		manyWords[i] = &NGWord{Word: "never-match"}
	}
	manyWords[127].Word = "boundary"
	manyWords[129].Word = "boundary"
	idsAtBoundary, err := matchingCommentIDs(context.Background(), tx, comments, manyWords)
	if err != nil {
		t.Fatal(err)
	}
	if len(idsAtBoundary) != 130 {
		t.Fatalf("word chunk boundary: got %d IDs", len(idsAtBoundary))
	}
	if ids, err := matchingCommentIDs(context.Background(), tx, comments, nil); err != nil || len(ids) != 0 {
		t.Fatalf("empty NG words: %v %v", ids, err)
	}
	if ids, err := matchingCommentIDs(context.Background(), tx, nil, manyWords); err != nil || len(ids) != 0 {
		t.Fatalf("empty comments: %v %v", ids, err)
	}
	words := []*NGWord{{Word: "first"}, {Word: "fall%"}}
	if err := deleteMatchingComments(context.Background(), tx, 10, words); err != nil {
		t.Fatal(err)
	}
	var ids []int64
	if err := tx.Select(&ids, "SELECT id FROM livecomments ORDER BY id"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(ids, []int64{2, 3, 5}) {
		t.Fatal(ids)
	}
}

func TestReservationBatchMySQL(t *testing.T) {
	db := performanceDB(t)
	start := time.Date(2023, 11, 26, 1, 0, 0, 0, time.UTC).Unix()
	end := start + 3600
	db.MustExec("INSERT INTO reservation_slots(slot,start_at,end_at) VALUES (2,?,?)", start, end)
	body := fmt.Sprintf(`{"tags":[1,2,1],"title":"reserved","description":"d","playlist_url":"p","thumbnail_url":"t","start_at":%d,"end_at":%d}`, start, end)
	var wg sync.WaitGroup
	codes := make(chan int, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes <- performanceRequest(reserveLivestreamHandler, "/api/livestream/reservation", "/api/livestream/reservation", http.MethodPost, body, 1).Code
		}()
	}
	wg.Wait()
	close(codes)
	successes := 0
	for code := range codes {
		if code == 201 {
			successes++
		} else if code != 400 {
			t.Fatalf("unexpected HTTP %d", code)
		}
	}
	var slots int
	if err := db.Get(&slots, "SELECT slot FROM reservation_slots WHERE start_at=?", start); err != nil {
		t.Fatal(err)
	}
	if successes != 2 || slots != 0 {
		t.Fatalf("successes=%d slots=%d", successes, slots)
	}
	var tags []int64
	if err := db.Select(&tags, "SELECT tag_id FROM livestream_tags WHERE livestream_id=(SELECT MAX(id) FROM livestreams) ORDER BY id"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(tags, []int64{1, 2, 1}) {
		t.Fatal(tags)
	}
}

func TestIndexPlansMySQL(t *testing.T) {
	db := performanceDB(t)
	// 十分な行数を入れて、少数行テーブルに対する全走査の最適化と区別する。
	var streams, tags, viewers, comments, reactions, reports, words, slots []string
	for i := 1000; i < 3000; i++ {
		streams = append(streams, fmt.Sprintf("(%d,3,'s','','','',1,2)", i))
		tags = append(tags, fmt.Sprintf("(%d,2)", i))
		viewers = append(viewers, fmt.Sprintf("(3,%d,1)", i))
		comments = append(comments, fmt.Sprintf("(3,%d,'text',0,1)", i))
		reactions = append(reactions, fmt.Sprintf("(3,%d,'a',1)", i))
		reports = append(reports, fmt.Sprintf("(3,%d,1,1)", i))
		words = append(words, fmt.Sprintf("(3,%d,'w',1)", i))
		slots = append(slots, fmt.Sprintf("(2,%d,%d)", i, i+1))
	}
	for _, insert := range []string{
		"INSERT INTO livestreams(id,user_id,title,description,playlist_url,thumbnail_url,start_at,end_at) VALUES " + strings.Join(streams, ","),
		"INSERT INTO livestream_tags(livestream_id,tag_id) VALUES " + strings.Join(tags, ","),
		"INSERT INTO livestream_viewers_history(user_id,livestream_id,created_at) VALUES " + strings.Join(viewers, ","),
		"INSERT INTO livecomments(user_id,livestream_id,comment,tip,created_at) VALUES " + strings.Join(comments, ","),
		"INSERT INTO reactions(user_id,livestream_id,emoji_name,created_at) VALUES " + strings.Join(reactions, ","),
		"INSERT INTO livecomment_reports(user_id,livestream_id,livecomment_id,created_at) VALUES " + strings.Join(reports, ","),
		"INSERT INTO ng_words(user_id,livestream_id,word,created_at) VALUES " + strings.Join(words, ","),
		"INSERT INTO reservation_slots(slot,start_at,end_at) VALUES " + strings.Join(slots, ","),
	} {
		db.MustExec(insert)
	}
	cases := []struct{ query, index string }{
		{"SELECT * FROM livestreams WHERE user_id=1", "livestreams_user_id"},
		{"SELECT * FROM livestream_tags WHERE tag_id IN (1) ORDER BY livestream_id DESC", "livestream_tags_tag_livestream"},
		{"SELECT * FROM livecomments WHERE livestream_id=10 ORDER BY created_at DESC LIMIT 10", "livecomments_livestream_created"},
		{"SELECT * FROM reactions WHERE livestream_id=10 ORDER BY created_at DESC LIMIT 10", "reactions_livestream_created"},
		{"SELECT COUNT(*) FROM livestream_viewers_history WHERE livestream_id=10", "viewers_livestream_user"},
		{"SELECT * FROM livecomment_reports WHERE livestream_id=10", "reports_livestream"},
		{"SELECT * FROM ng_words WHERE livestream_id=10", "ng_words_livestream"},
		{"SELECT * FROM ng_words WHERE user_id=1 AND livestream_id=10", "ng_words_user_livestream|ng_words_livestream"},
		{"SELECT * FROM reservation_slots WHERE start_at>=2999 AND end_at<=3000 FOR UPDATE", "reservation_slots_start_end"},
		{"SELECT * FROM reservation_slots WHERE start_at>=1000 AND end_at<=1001 FOR UPDATE", "reservation_slots_end_start"},
	}
	for _, c := range cases {
		t.Run(c.index+c.query, func(t *testing.T) {
			rows, err := db.Queryx("EXPLAIN " + c.query)
			if err != nil {
				t.Fatal(err)
			}
			defer rows.Close()
			if !rows.Next() {
				t.Fatal("no explain row")
			}
			row := map[string]interface{}{}
			if err := rows.MapScan(row); err != nil {
				t.Fatal(err)
			}
			key := fmt.Sprintf("%s", row["key"])
			if !strings.Contains("|"+c.index+"|", "|"+key+"|") {
				t.Fatalf("key=%s expected=%s: %#v", key, c.index, row)
			}
			t.Logf("index=%s rows=%v", key, row["rows"])
		})
	}
}
