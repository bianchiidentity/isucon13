package main

// develop (288f03f) の旧経路を保持し、MySQL 上でレスポンスと件数を比較するための参照実装。
// 本番コードからは呼ばない。
import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo-contrib/session"
	"github.com/labstack/echo/v4"
	"net/http"
	"os"
	"sort"
	"strconv"
)

func legacyFillUserResponse(ctx context.Context, tx *sqlx.Tx, userModel UserModel) (User, error) {
	themeModel := ThemeModel{}
	if err := tx.GetContext(ctx, &themeModel, "SELECT * FROM themes WHERE user_id = ?", userModel.ID); err != nil {
		return User{}, err
	}

	var image []byte
	if err := tx.GetContext(ctx, &image, "SELECT image FROM icons WHERE user_id = ?", userModel.ID); err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			return User{}, err
		}
		image, err = os.ReadFile(fallbackImage)
		if err != nil {
			return User{}, err
		}
	}
	iconHash := sha256.Sum256(image)

	user := User{
		ID:          userModel.ID,
		Name:        userModel.Name,
		DisplayName: userModel.DisplayName,
		Description: userModel.Description,
		Theme: Theme{
			ID:       themeModel.ID,
			DarkMode: themeModel.DarkMode,
		},
		IconHash: fmt.Sprintf("%x", iconHash),
	}

	return user, nil
}

func legacyFillLivestreamResponse(ctx context.Context, tx *sqlx.Tx, livestreamModel LivestreamModel) (Livestream, error) {
	ownerModel := UserModel{}
	if err := tx.GetContext(ctx, &ownerModel, "SELECT * FROM users WHERE id = ?", livestreamModel.UserID); err != nil {
		return Livestream{}, err
	}
	owner, err := legacyFillUserResponse(ctx, tx, ownerModel)
	if err != nil {
		return Livestream{}, err
	}

	var livestreamTagModels []*LivestreamTagModel
	if err := tx.SelectContext(ctx, &livestreamTagModels, "SELECT * FROM livestream_tags WHERE livestream_id = ?", livestreamModel.ID); err != nil {
		return Livestream{}, err
	}

	tags := make([]Tag, len(livestreamTagModels))
	for i := range livestreamTagModels {
		tagModel := TagModel{}
		if err := tx.GetContext(ctx, &tagModel, "SELECT * FROM tags WHERE id = ?", livestreamTagModels[i].TagID); err != nil {
			return Livestream{}, err
		}

		tags[i] = Tag{
			ID:   tagModel.ID,
			Name: tagModel.Name,
		}
	}

	livestream := Livestream{
		ID:           livestreamModel.ID,
		Owner:        owner,
		Title:        livestreamModel.Title,
		Tags:         tags,
		Description:  livestreamModel.Description,
		PlaylistUrl:  livestreamModel.PlaylistUrl,
		ThumbnailUrl: livestreamModel.ThumbnailUrl,
		StartAt:      livestreamModel.StartAt,
		EndAt:        livestreamModel.EndAt,
	}
	return livestream, nil
}

func legacySearchLivestreamsHandler(c echo.Context) error {
	ctx := c.Request().Context()
	keyTagName := c.QueryParam("tag")

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	var livestreamModels []*LivestreamModel
	if c.QueryParam("tag") != "" {
		// タグによる取得
		var tagIDList []int
		if err := tx.SelectContext(ctx, &tagIDList, "SELECT id FROM tags WHERE name = ?", keyTagName); err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get tags: "+err.Error())
		}

		query, params, err := sqlx.In("SELECT * FROM livestream_tags WHERE tag_id IN (?) ORDER BY livestream_id DESC", tagIDList)
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to construct IN query: "+err.Error())
		}
		var keyTaggedLivestreams []*LivestreamTagModel
		if err := tx.SelectContext(ctx, &keyTaggedLivestreams, query, params...); err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get keyTaggedLivestreams: "+err.Error())
		}

		for _, keyTaggedLivestream := range keyTaggedLivestreams {
			ls := LivestreamModel{}
			if err := tx.GetContext(ctx, &ls, "SELECT * FROM livestreams WHERE id = ?", keyTaggedLivestream.LivestreamID); err != nil {
				return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestreams: "+err.Error())
			}

			livestreamModels = append(livestreamModels, &ls)
		}
	} else {
		// 検索条件なし
		query := `SELECT * FROM livestreams ORDER BY id DESC`
		if c.QueryParam("limit") != "" {
			limit, err := strconv.Atoi(c.QueryParam("limit"))
			if err != nil {
				return echo.NewHTTPError(http.StatusBadRequest, "limit query parameter must be integer")
			}
			query += fmt.Sprintf(" LIMIT %d", limit)
		}

		if err := tx.SelectContext(ctx, &livestreamModels, query); err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestreams: "+err.Error())
		}
	}

	livestreams := make([]Livestream, len(livestreamModels))
	for i := range livestreamModels {
		livestream, err := legacyFillLivestreamResponse(ctx, tx, *livestreamModels[i])
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fill livestream: "+err.Error())
		}
		livestreams[i] = livestream
	}

	if err := tx.Commit(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to commit: "+err.Error())
	}

	return c.JSON(http.StatusOK, livestreams)
}

func legacyGetMyLivestreamsHandler(c echo.Context) error {
	ctx := c.Request().Context()
	if err := verifyUserSession(c); err != nil {
		return err
	}

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	// error already checked
	sess, _ := session.Get(defaultSessionIDKey, c)
	// existence already checked
	userID := sess.Values[defaultUserIDKey].(int64)

	var livestreamModels []*LivestreamModel
	if err := tx.SelectContext(ctx, &livestreamModels, "SELECT * FROM livestreams WHERE user_id = ?", userID); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestreams: "+err.Error())
	}
	livestreams := make([]Livestream, len(livestreamModels))
	for i := range livestreamModels {
		livestream, err := legacyFillLivestreamResponse(ctx, tx, *livestreamModels[i])
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fill livestream: "+err.Error())
		}
		livestreams[i] = livestream
	}

	if err := tx.Commit(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to commit: "+err.Error())
	}

	return c.JSON(http.StatusOK, livestreams)
}

func legacyGetUserLivestreamsHandler(c echo.Context) error {
	ctx := c.Request().Context()
	if err := verifyUserSession(c); err != nil {
		return err
	}

	username := c.Param("username")

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	var user UserModel
	if err := tx.GetContext(ctx, &user, "SELECT * FROM users WHERE name = ?", username); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return echo.NewHTTPError(http.StatusNotFound, "user not found")
		} else {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get user: "+err.Error())
		}
	}

	var livestreamModels []*LivestreamModel
	if err := tx.SelectContext(ctx, &livestreamModels, "SELECT * FROM livestreams WHERE user_id = ?", user.ID); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestreams: "+err.Error())
	}
	livestreams := make([]Livestream, len(livestreamModels))
	for i := range livestreamModels {
		livestream, err := legacyFillLivestreamResponse(ctx, tx, *livestreamModels[i])
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fill livestream: "+err.Error())
		}
		livestreams[i] = livestream
	}

	if err := tx.Commit(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to commit: "+err.Error())
	}

	return c.JSON(http.StatusOK, livestreams)
}

// viewerテーブルの廃止

func legacyGetLivecommentReportsHandler(c echo.Context) error {
	ctx := c.Request().Context()

	if err := verifyUserSession(c); err != nil {
		return err
	}

	livestreamID, err := strconv.Atoi(c.Param("livestream_id"))
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "livestream_id in path must be integer")
	}

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	var livestreamModel LivestreamModel
	if err := tx.GetContext(ctx, &livestreamModel, "SELECT * FROM livestreams WHERE id = ?", livestreamID); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestream: "+err.Error())
	}

	// error already check
	sess, _ := session.Get(defaultSessionIDKey, c)
	// existence already check
	userID := sess.Values[defaultUserIDKey].(int64)

	if livestreamModel.UserID != userID {
		return echo.NewHTTPError(http.StatusForbidden, "can't get other streamer's livecomment reports")
	}

	var reportModels []*LivecommentReportModel
	if err := tx.SelectContext(ctx, &reportModels, "SELECT * FROM livecomment_reports WHERE livestream_id = ?", livestreamID); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livecomment reports: "+err.Error())
	}

	reports := make([]LivecommentReport, len(reportModels))
	for i := range reportModels {
		report, err := legacyFillLivecommentReportResponse(ctx, tx, *reportModels[i])
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fill livecomment report: "+err.Error())
		}
		reports[i] = report
	}

	if err := tx.Commit(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to commit: "+err.Error())
	}

	return c.JSON(http.StatusOK, reports)
}

func legacyFillLivecommentResponse(ctx context.Context, tx *sqlx.Tx, livecommentModel LivecommentModel) (Livecomment, error) {
	commentOwnerModel := UserModel{}
	if err := tx.GetContext(ctx, &commentOwnerModel, "SELECT * FROM users WHERE id = ?", livecommentModel.UserID); err != nil {
		return Livecomment{}, err
	}
	commentOwner, err := legacyFillUserResponse(ctx, tx, commentOwnerModel)
	if err != nil {
		return Livecomment{}, err
	}

	livestreamModel := LivestreamModel{}
	if err := tx.GetContext(ctx, &livestreamModel, "SELECT * FROM livestreams WHERE id = ?", livecommentModel.LivestreamID); err != nil {
		return Livecomment{}, err
	}
	livestream, err := legacyFillLivestreamResponse(ctx, tx, livestreamModel)
	if err != nil {
		return Livecomment{}, err
	}

	livecomment := Livecomment{
		ID:         livecommentModel.ID,
		User:       commentOwner,
		Livestream: livestream,
		Comment:    livecommentModel.Comment,
		Tip:        livecommentModel.Tip,
		CreatedAt:  livecommentModel.CreatedAt,
	}

	return livecomment, nil
}

// legacyFillLivecommentResponseWithLivestream は組み立て済みの配信情報を埋め込んで、コメントのレスポンスを作る

func legacyFillLivecommentReportResponse(ctx context.Context, tx *sqlx.Tx, reportModel LivecommentReportModel) (LivecommentReport, error) {
	reporterModel := UserModel{}
	if err := tx.GetContext(ctx, &reporterModel, "SELECT * FROM users WHERE id = ?", reportModel.UserID); err != nil {
		return LivecommentReport{}, err
	}
	reporter, err := legacyFillUserResponse(ctx, tx, reporterModel)
	if err != nil {
		return LivecommentReport{}, err
	}

	livecommentModel := LivecommentModel{}
	if err := tx.GetContext(ctx, &livecommentModel, "SELECT * FROM livecomments WHERE id = ?", reportModel.LivecommentID); err != nil {
		return LivecommentReport{}, err
	}
	livecomment, err := legacyFillLivecommentResponse(ctx, tx, livecommentModel)
	if err != nil {
		return LivecommentReport{}, err
	}

	report := LivecommentReport{
		ID:          reportModel.ID,
		Reporter:    reporter,
		Livecomment: livecomment,
		CreatedAt:   reportModel.CreatedAt,
	}
	return report, nil
}

func legacyFillLivecommentResponseWithLivestream(ctx context.Context, tx *sqlx.Tx, livecommentModel LivecommentModel, livestream Livestream) (Livecomment, error) {
	commentOwnerModel := UserModel{}
	if err := tx.GetContext(ctx, &commentOwnerModel, "SELECT * FROM users WHERE id = ?", livecommentModel.UserID); err != nil {
		return Livecomment{}, err
	}
	commentOwner, err := legacyFillUserResponse(ctx, tx, commentOwnerModel)
	if err != nil {
		return Livecomment{}, err
	}

	return Livecomment{
		ID:         livecommentModel.ID,
		User:       commentOwner,
		Livestream: livestream,
		Comment:    livecommentModel.Comment,
		Tip:        livecommentModel.Tip,
		CreatedAt:  livecommentModel.CreatedAt,
	}, nil
}

func legacyGetLivecommentsHandler(c echo.Context) error {
	ctx := c.Request().Context()

	if err := verifyUserSession(c); err != nil {
		// echo.NewHTTPErrorが返っているのでそのまま出力
		return err
	}

	livestreamID, err := strconv.Atoi(c.Param("livestream_id"))
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "livestream_id in path must be integer")
	}

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	query := "SELECT * FROM livecomments WHERE livestream_id = ? ORDER BY created_at DESC"
	if c.QueryParam("limit") != "" {
		limit, err := strconv.Atoi(c.QueryParam("limit"))
		if err != nil {
			return echo.NewHTTPError(http.StatusBadRequest, "limit query parameter must be integer")
		}
		query += fmt.Sprintf(" LIMIT %d", limit)
	}

	livecommentModels := []LivecommentModel{}
	err = tx.SelectContext(ctx, &livecommentModels, query, livestreamID)
	if errors.Is(err, sql.ErrNoRows) {
		return c.JSON(http.StatusOK, []*Livecomment{})
	}
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livecomments: "+err.Error())
	}

	// 全コメントが同じ配信に属するため、配信情報は一度だけ組み立てて使い回す
	var livestream Livestream
	if len(livecommentModels) > 0 {
		livestreamModel := LivestreamModel{}
		if err := tx.GetContext(ctx, &livestreamModel, "SELECT * FROM livestreams WHERE id = ?", livecommentModels[0].LivestreamID); err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fil livecomments: "+err.Error())
		}
		livestream, err = legacyFillLivestreamResponse(ctx, tx, livestreamModel)
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fil livecomments: "+err.Error())
		}
	}

	livecomments := make([]Livecomment, len(livecommentModels))
	for i := range livecommentModels {
		livecomment, err := legacyFillLivecommentResponseWithLivestream(ctx, tx, livecommentModels[i], livestream)
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fil livecomments: "+err.Error())
		}

		livecomments[i] = livecomment
	}

	if err := tx.Commit(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to commit: "+err.Error())
	}

	return c.JSON(http.StatusOK, livecomments)
}

func legacyFillReactionResponse(ctx context.Context, tx *sqlx.Tx, reactionModel ReactionModel) (Reaction, error) {
	userModel := UserModel{}
	if err := tx.GetContext(ctx, &userModel, "SELECT * FROM users WHERE id = ?", reactionModel.UserID); err != nil {
		return Reaction{}, err
	}
	user, err := legacyFillUserResponse(ctx, tx, userModel)
	if err != nil {
		return Reaction{}, err
	}

	livestreamModel := LivestreamModel{}
	if err := tx.GetContext(ctx, &livestreamModel, "SELECT * FROM livestreams WHERE id = ?", reactionModel.LivestreamID); err != nil {
		return Reaction{}, err
	}
	livestream, err := legacyFillLivestreamResponse(ctx, tx, livestreamModel)
	if err != nil {
		return Reaction{}, err
	}

	reaction := Reaction{
		ID:         reactionModel.ID,
		EmojiName:  reactionModel.EmojiName,
		User:       user,
		Livestream: livestream,
		CreatedAt:  reactionModel.CreatedAt,
	}

	return reaction, nil
}

func legacyGetReactionsHandler(c echo.Context) error {
	ctx := c.Request().Context()

	if err := verifyUserSession(c); err != nil {
		// echo.NewHTTPErrorが返っているのでそのまま出力
		return err
	}

	livestreamID, err := strconv.Atoi(c.Param("livestream_id"))
	if err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "livestream_id in path must be integer")
	}

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	query := "SELECT * FROM reactions WHERE livestream_id = ? ORDER BY created_at DESC"
	if c.QueryParam("limit") != "" {
		limit, err := strconv.Atoi(c.QueryParam("limit"))
		if err != nil {
			return echo.NewHTTPError(http.StatusBadRequest, "limit query parameter must be integer")
		}
		query += fmt.Sprintf(" LIMIT %d", limit)
	}

	reactionModels := []ReactionModel{}
	if err := tx.SelectContext(ctx, &reactionModels, query, livestreamID); err != nil {
		return echo.NewHTTPError(http.StatusNotFound, "failed to get reactions")
	}

	reactions := make([]Reaction, len(reactionModels))
	for i := range reactionModels {
		reaction, err := legacyFillReactionResponse(ctx, tx, reactionModels[i])
		if err != nil {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to fill reaction: "+err.Error())
		}

		reactions[i] = reaction
	}

	if err := tx.Commit(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to commit: "+err.Error())
	}

	return c.JSON(http.StatusOK, reactions)
}

func legacyGetUserStatisticsHandler(c echo.Context) error {
	ctx := c.Request().Context()

	if err := verifyUserSession(c); err != nil {
		// echo.NewHTTPErrorが返っているのでそのまま出力
		return err
	}

	username := c.Param("username")
	// ユーザごとに、紐づく配信について、累計リアクション数、累計ライブコメント数、累計売上金額を算出
	// また、現在の合計視聴者数もだす

	tx, err := dbConn.BeginTxx(ctx, nil)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to begin transaction: "+err.Error())
	}
	defer tx.Rollback()

	var user UserModel
	if err := tx.GetContext(ctx, &user, "SELECT * FROM users WHERE name = ?", username); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return echo.NewHTTPError(http.StatusBadRequest, "not found user that has the given username")
		} else {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get user: "+err.Error())
		}
	}

	// ランク算出
	// リアクション数とチップ合計をそれぞれユーザ単位で集約してから結合する（明細同士を JOIN すると件数が掛け算で増える）
	var ranking UserRanking
	query := `
	SELECT u.name AS username,
		CAST(IFNULL(r.cnt, 0) + IFNULL(c.tips, 0) AS SIGNED) AS score
	FROM users u
	LEFT JOIN (
		SELECT l.user_id, COUNT(*) AS cnt FROM livestreams l
		INNER JOIN reactions r ON r.livestream_id = l.id
		GROUP BY l.user_id
	) r ON r.user_id = u.id
	LEFT JOIN (
		SELECT l.user_id, SUM(l2.tip) AS tips FROM livestreams l
		INNER JOIN livecomments l2 ON l2.livestream_id = l.id
		GROUP BY l.user_id
	) c ON c.user_id = u.id`
	if err := tx.SelectContext(ctx, &ranking, query); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get user ranking: "+err.Error())
	}
	sort.Sort(ranking)

	var rank int64 = 1
	for i := len(ranking) - 1; i >= 0; i-- {
		entry := ranking[i]
		if entry.Username == username {
			break
		}
		rank++
	}

	// リアクション数
	var totalReactions int64
	query = `SELECT COUNT(*) FROM users u
    INNER JOIN livestreams l ON l.user_id = u.id
    INNER JOIN reactions r ON r.livestream_id = l.id
    WHERE u.name = ?
	`
	if err := tx.GetContext(ctx, &totalReactions, query, username); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to count total reactions: "+err.Error())
	}

	// ライブコメント数、チップ合計
	var totalLivecomments int64
	var totalTip int64
	var livestreams []*LivestreamModel
	if err := tx.SelectContext(ctx, &livestreams, "SELECT * FROM livestreams WHERE user_id = ?", user.ID); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestreams: "+err.Error())
	}

	for _, livestream := range livestreams {
		var livecomments []*LivecommentModel
		if err := tx.SelectContext(ctx, &livecomments, "SELECT * FROM livecomments WHERE livestream_id = ?", livestream.ID); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livecomments: "+err.Error())
		}

		for _, livecomment := range livecomments {
			totalTip += livecomment.Tip
			totalLivecomments++
		}
	}

	// 合計視聴者数
	var viewersCount int64
	for _, livestream := range livestreams {
		var cnt int64
		if err := tx.GetContext(ctx, &cnt, "SELECT COUNT(*) FROM livestream_viewers_history WHERE livestream_id = ?", livestream.ID); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return echo.NewHTTPError(http.StatusInternalServerError, "failed to get livestream_view_history: "+err.Error())
		}
		viewersCount += cnt
	}

	// お気に入り絵文字
	var favoriteEmoji string
	query = `
	SELECT r.emoji_name
	FROM users u
	INNER JOIN livestreams l ON l.user_id = u.id
	INNER JOIN reactions r ON r.livestream_id = l.id
	WHERE u.name = ?
	GROUP BY emoji_name
	ORDER BY COUNT(*) DESC, emoji_name DESC
	LIMIT 1
	`
	if err := tx.GetContext(ctx, &favoriteEmoji, query, username); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to find favorite emoji: "+err.Error())
	}

	stats := UserStatistics{
		Rank:              rank,
		ViewersCount:      viewersCount,
		TotalReactions:    totalReactions,
		TotalLivecomments: totalLivecomments,
		TotalTip:          totalTip,
		FavoriteEmoji:     favoriteEmoji,
	}
	return c.JSON(http.StatusOK, stats)
}
