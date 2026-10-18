package main

import (
	"context"
	"database/sql"

	"github.com/jmoiron/sqlx"
)

func uniqueResponseIDs(ids []int64) []int64 {
	seen := map[int64]bool{}
	result := make([]int64, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			result = append(result, id)
		}
	}
	return result
}

// 空の IN を作らず、レスポンスの重複は組み立て時に元の一覧から復元する。
func selectResponseIDs(ctx context.Context, tx *sqlx.Tx, dest interface{}, query string, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	query, args, err := sqlx.In(query, uniqueResponseIDs(ids))
	if err != nil {
		return err
	}
	return tx.SelectContext(ctx, dest, query, args...)
}

func fillUsersByIDs(ctx context.Context, tx *sqlx.Tx, userIDs []int64) (map[int64]User, error) {
	userIDs = uniqueResponseIDs(userIDs)
	if len(userIDs) == 0 {
		return map[int64]User{}, nil
	}
	var users []UserModel
	if err := selectResponseIDs(ctx, tx, &users, "SELECT * FROM users WHERE id IN (?)", userIDs); err != nil {
		return nil, err
	}
	var themes []ThemeModel
	if err := selectResponseIDs(ctx, tx, &themes, "SELECT * FROM themes WHERE user_id IN (?) ORDER BY id", userIDs); err != nil {
		return nil, err
	}
	iconHashes, err := getIconHashes(ctx, tx, userIDs)
	if err != nil {
		return nil, err
	}
	themesByUser := map[int64]ThemeModel{}
	for _, theme := range themes {
		if _, ok := themesByUser[theme.UserID]; !ok {
			themesByUser[theme.UserID] = theme
		}
	}
	owners := map[int64]User{}
	for _, user := range users {
		theme, ok := themesByUser[user.ID]
		if !ok {
			return nil, sql.ErrNoRows
		}
		owners[user.ID] = User{ID: user.ID, Name: user.Name, DisplayName: user.DisplayName, Description: user.Description,
			Theme: Theme{ID: theme.ID, DarkMode: theme.DarkMode}, IconHash: iconHashes[user.ID]}
	}
	for _, id := range userIDs {
		if _, ok := owners[id]; !ok {
			return nil, sql.ErrNoRows
		}
	}
	return owners, nil
}

// 一覧レスポンスの一括取得。同じトランザクションの読み取りを保つ。
func fillLivestreamResponses(ctx context.Context, tx *sqlx.Tx, models []*LivestreamModel) ([]Livestream, error) {
	result := make([]Livestream, len(models))
	if len(models) == 0 {
		return result, nil
	}
	userIDs, streamIDs := []int64{}, []int64{}
	seenUsers, seenStreams := map[int64]bool{}, map[int64]bool{}
	for _, model := range models {
		if !seenUsers[model.UserID] {
			userIDs = append(userIDs, model.UserID)
			seenUsers[model.UserID] = true
		}
		if !seenStreams[model.ID] {
			streamIDs = append(streamIDs, model.ID)
			seenStreams[model.ID] = true
		}
	}
	owners, err := fillUsersByIDs(ctx, tx, userIDs)
	if err != nil {
		return nil, err
	}
	var links []LivestreamTagModel
	// 既存の livestream_id 索引による取得順（同一配信内は主キー順）を維持する。
	if err := selectResponseIDs(ctx, tx, &links, "SELECT * FROM livestream_tags WHERE livestream_id IN (?) ORDER BY livestream_id, id", streamIDs); err != nil {
		return nil, err
	}
	tagIDs := []int64{}
	seenTags := map[int64]bool{}
	for _, link := range links {
		if !seenTags[link.TagID] {
			tagIDs = append(tagIDs, link.TagID)
			seenTags[link.TagID] = true
		}
	}
	tagsByID := map[int64]Tag{}
	if len(tagIDs) > 0 {
		var tags []TagModel
		if err := selectResponseIDs(ctx, tx, &tags, "SELECT * FROM tags WHERE id IN (?)", tagIDs); err != nil {
			return nil, err
		}
		for _, tag := range tags {
			tagsByID[tag.ID] = Tag{ID: tag.ID, Name: tag.Name}
		}
	}
	streamTags := map[int64][]Tag{}
	for _, link := range links {
		tag, ok := tagsByID[link.TagID]
		if !ok {
			return nil, sql.ErrNoRows
		}
		streamTags[link.LivestreamID] = append(streamTags[link.LivestreamID], tag)
	}
	for i, model := range models {
		owner, ok := owners[model.UserID]
		if !ok {
			return nil, sql.ErrNoRows
		}
		tags := streamTags[model.ID]
		if tags == nil {
			tags = []Tag{}
		}
		result[i] = Livestream{ID: model.ID, Owner: owner, Title: model.Title, Description: model.Description,
			PlaylistUrl: model.PlaylistUrl, ThumbnailUrl: model.ThumbnailUrl, Tags: tags, StartAt: model.StartAt, EndAt: model.EndAt}
	}
	return result, nil
}

func livestreamResponsesByIDs(ctx context.Context, tx *sqlx.Tx, ids []int64) (map[int64]Livestream, error) {
	var models []*LivestreamModel
	if err := selectResponseIDs(ctx, tx, &models, "SELECT * FROM livestreams WHERE id IN (?)", ids); err != nil {
		return nil, err
	}
	responses, err := fillLivestreamResponses(ctx, tx, models)
	if err != nil {
		return nil, err
	}
	result := map[int64]Livestream{}
	for _, response := range responses {
		result[response.ID] = response
	}
	for _, id := range ids {
		if _, ok := result[id]; !ok {
			return nil, sql.ErrNoRows
		}
	}
	return result, nil
}

func fillLivecommentResponses(ctx context.Context, tx *sqlx.Tx, models []LivecommentModel) ([]Livecomment, error) {
	result := make([]Livecomment, len(models))
	if len(models) == 0 {
		return result, nil
	}
	var streamIDs, userIDs []int64
	for _, m := range models {
		streamIDs = append(streamIDs, m.LivestreamID)
		userIDs = append(userIDs, m.UserID)
	}
	streams, err := livestreamResponsesByIDs(ctx, tx, streamIDs)
	if err != nil {
		return nil, err
	}
	users, err := fillUsersByIDs(ctx, tx, userIDs)
	if err != nil {
		return nil, err
	}
	for i, m := range models {
		result[i] = Livecomment{ID: m.ID, User: users[m.UserID], Livestream: streams[m.LivestreamID], Comment: m.Comment, Tip: m.Tip, CreatedAt: m.CreatedAt}
	}
	return result, nil
}

func fillReactionResponses(ctx context.Context, tx *sqlx.Tx, models []ReactionModel) ([]Reaction, error) {
	result := make([]Reaction, len(models))
	if len(models) == 0 {
		return result, nil
	}
	var streamIDs, userIDs []int64
	for _, m := range models {
		streamIDs = append(streamIDs, m.LivestreamID)
		userIDs = append(userIDs, m.UserID)
	}
	streams, err := livestreamResponsesByIDs(ctx, tx, streamIDs)
	if err != nil {
		return nil, err
	}
	users, err := fillUsersByIDs(ctx, tx, userIDs)
	if err != nil {
		return nil, err
	}
	for i, m := range models {
		result[i] = Reaction{ID: m.ID, User: users[m.UserID], Livestream: streams[m.LivestreamID], EmojiName: m.EmojiName, CreatedAt: m.CreatedAt}
	}
	return result, nil
}

func fillReportResponses(ctx context.Context, tx *sqlx.Tx, models []*LivecommentReportModel) ([]LivecommentReport, error) {
	result := make([]LivecommentReport, len(models))
	if len(models) == 0 {
		return result, nil
	}
	var commentIDs, userIDs []int64
	for _, m := range models {
		commentIDs = append(commentIDs, m.LivecommentID)
		userIDs = append(userIDs, m.UserID)
	}
	var comments []LivecommentModel
	if err := selectResponseIDs(ctx, tx, &comments, "SELECT * FROM livecomments WHERE id IN (?)", commentIDs); err != nil {
		return nil, err
	}
	responses, err := fillLivecommentResponses(ctx, tx, comments)
	if err != nil {
		return nil, err
	}
	byID := map[int64]Livecomment{}
	for _, response := range responses {
		byID[response.ID] = response
	}
	users, err := fillUsersByIDs(ctx, tx, userIDs)
	if err != nil {
		return nil, err
	}
	for i, m := range models {
		comment, ok := byID[m.LivecommentID]
		if !ok {
			return nil, sql.ErrNoRows
		}
		result[i] = LivecommentReport{ID: m.ID, Reporter: users[m.UserID], Livecomment: comment, CreatedAt: m.CreatedAt}
	}
	return result, nil
}
