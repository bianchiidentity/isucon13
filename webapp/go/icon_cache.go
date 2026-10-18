package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/jmoiron/sqlx"
)

// アイコンのハッシュ（user_id → sha256 の16進）をプロセス内に持つ。アプリサーバーが 1 台の前提。
// 無ければ DB から読んで埋め、アイコンの更新時はコミット後に上書きする。
// 読み込みで埋めるときは既存の値を上書きしない。古いスナップショットから読んだ値が、更新後の値を消さないようにするため。
var (
	iconHashMu    sync.RWMutex
	iconHashCache = map[int64]string{}

	fallbackIconHashOnce  sync.Once
	fallbackIconHashValue string
	fallbackIconHashErr   error
)

func calcIconHash(image []byte) string {
	return fmt.Sprintf("%x", sha256.Sum256(image))
}

func fallbackIconHash() (string, error) {
	fallbackIconHashOnce.Do(func() {
		image, err := os.ReadFile(fallbackImage)
		if err != nil {
			fallbackIconHashErr = err
			return
		}
		fallbackIconHashValue = calcIconHash(image)
	})
	return fallbackIconHashValue, fallbackIconHashErr
}

func loadIconHash(userID int64) (string, bool) {
	iconHashMu.RLock()
	defer iconHashMu.RUnlock()
	hash, ok := iconHashCache[userID]
	return hash, ok
}

// loadOrStoreIconHash は値が無いときだけ入れ、キャッシュに入っている値を返す。
func loadOrStoreIconHash(userID int64, hash string) string {
	iconHashMu.Lock()
	defer iconHashMu.Unlock()
	if current, ok := iconHashCache[userID]; ok {
		return current
	}
	iconHashCache[userID] = hash
	return hash
}

func setIconHash(userID int64, image []byte) {
	hash := calcIconHash(image)
	iconHashMu.Lock()
	defer iconHashMu.Unlock()
	iconHashCache[userID] = hash
}

func resetIconCache() {
	iconHashMu.Lock()
	defer iconHashMu.Unlock()
	iconHashCache = map[int64]string{}
}

func getIconHash(ctx context.Context, tx *sqlx.Tx, userID int64) (string, error) {
	if hash, ok := loadIconHash(userID); ok {
		return hash, nil
	}

	var image []byte
	if err := tx.GetContext(ctx, &image, "SELECT image FROM icons WHERE user_id = ?", userID); err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			return "", err
		}
		hash, err := fallbackIconHash()
		if err != nil {
			return "", err
		}
		return loadOrStoreIconHash(userID, hash), nil
	}
	return loadOrStoreIconHash(userID, calcIconHash(image)), nil
}

// getIconHashes は複数ユーザーのハッシュを返す。キャッシュに無いユーザーだけを 1 回のクエリで読む。
func getIconHashes(ctx context.Context, tx *sqlx.Tx, userIDs []int64) (map[int64]string, error) {
	hashes := make(map[int64]string, len(userIDs))
	missing := []int64{}
	for _, userID := range userIDs {
		if hash, ok := loadIconHash(userID); ok {
			hashes[userID] = hash
		} else {
			missing = append(missing, userID)
		}
	}
	if len(missing) == 0 {
		return hashes, nil
	}

	query, args, err := sqlx.In("SELECT user_id, image FROM icons WHERE user_id IN (?) ORDER BY id", missing)
	if err != nil {
		return nil, err
	}
	var icons []struct {
		UserID int64  `db:"user_id"`
		Image  []byte `db:"image"`
	}
	if err := tx.SelectContext(ctx, &icons, query, args...); err != nil {
		return nil, err
	}
	for _, icon := range icons {
		if _, ok := hashes[icon.UserID]; !ok {
			hashes[icon.UserID] = loadOrStoreIconHash(icon.UserID, calcIconHash(icon.Image))
		}
	}
	for _, userID := range missing {
		if _, ok := hashes[userID]; ok {
			continue
		}
		hash, err := fallbackIconHash()
		if err != nil {
			return nil, err
		}
		hashes[userID] = loadOrStoreIconHash(userID, hash)
	}
	return hashes, nil
}
