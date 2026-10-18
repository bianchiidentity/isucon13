package main

import (
	"context"
	"strings"

	"github.com/jmoiron/sqlx"
)

// 元の LIKE と同じく、本文・パターンをどちらもパラメータとして比較する。
// テーブル列の照合順序や Go の文字列比較へ置き換えず、%・_・バックスラッシュの意味を保つ。
func matchingCommentIDs(ctx context.Context, tx *sqlx.Tx, comments []LivecommentModel, words []*NGWord) ([]int64, error) {
	const chunk = 128
	found := map[int64]bool{}
	result := []int64{}
	for start := 0; start < len(comments); start += chunk {
		end := start + chunk
		if end > len(comments) {
			end = len(comments)
		}
		for wordStart := 0; wordStart < len(words); wordStart += chunk {
			wordEnd := wordStart + chunk
			if wordEnd > len(words) {
				wordEnd = len(words)
			}
			texts, patterns := []string{}, []string{}
			args := []interface{}{}
			for _, comment := range comments[start:end] {
				texts = append(texts, "SELECT ? AS id, ? AS text")
				args = append(args, comment.ID, comment.Comment)
			}
			for _, word := range words[wordStart:wordEnd] {
				patterns = append(patterns, "SELECT CONCAT('%', ?, '%') AS pattern")
				args = append(args, word.Word)
			}
			query := "SELECT DISTINCT texts.id FROM (" + strings.Join(texts, " UNION ALL ") + ") AS texts INNER JOIN (" + strings.Join(patterns, " UNION ALL ") + ") AS patterns ON texts.text LIKE patterns.pattern"
			var ids []int64
			if err := tx.SelectContext(ctx, &ids, query, args...); err != nil {
				return nil, err
			}
			for _, id := range ids {
				if !found[id] {
					found[id] = true
					result = append(result, id)
				}
			}
		}
	}
	return result, nil
}

func deleteMatchingComments(ctx context.Context, tx *sqlx.Tx, livestreamID int, words []*NGWord) error {
	if len(words) == 0 {
		return nil
	}
	var comments []LivecommentModel
	if err := tx.SelectContext(ctx, &comments, "SELECT * FROM livecomments WHERE livestream_id = ?", livestreamID); err != nil {
		return err
	}
	ids, err := matchingCommentIDs(ctx, tx, comments, words)
	if err != nil {
		return err
	}
	for start := 0; start < len(ids); start += 256 {
		end := start + 256
		if end > len(ids) {
			end = len(ids)
		}
		query, args, err := sqlx.In("DELETE FROM livecomments WHERE livestream_id = ? AND id IN (?)", livestreamID, ids[start:end])
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, query, args...); err != nil {
			return err
		}
	}
	return nil
}
