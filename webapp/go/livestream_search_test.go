package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/jmoiron/sqlx"
)

func TestSearchBatchResponse(t *testing.T) {
	for _, missingIcon := range []bool{false, true} {
		t.Run(fmt.Sprintf("fallback=%v", missingIcon), func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			mock.ExpectBegin()
			tx, err := sqlx.NewDb(db, "sqlmock").Beginx()
			if err != nil {
				t.Fatal(err)
			}
			mock.ExpectQuery("SELECT \\* FROM users WHERE id IN").WithArgs(int64(7)).WillReturnRows(sqlmock.NewRows([]string{"id", "name", "display_name", "description", "password"}).AddRow(7, "owner", "Owner", "bio", "secret"))
			mock.ExpectQuery("SELECT \\* FROM themes WHERE user_id IN").WithArgs(int64(7)).WillReturnRows(sqlmock.NewRows([]string{"id", "user_id", "dark_mode"}).AddRow(3, 7, true))
			iconRows := sqlmock.NewRows([]string{"user_id", "image"})
			image := []byte("image")
			if missingIcon {
				image, err = os.ReadFile(fallbackImage)
				if err != nil {
					t.Fatal(err)
				}
			} else {
				iconRows.AddRow(7, image)
			}
			mock.ExpectQuery("SELECT user_id, image FROM icons WHERE user_id IN").WithArgs(int64(7)).WillReturnRows(iconRows)
			mock.ExpectQuery("SELECT \\* FROM livestream_tags WHERE livestream_id IN").WithArgs(int64(20), int64(10)).WillReturnRows(sqlmock.NewRows([]string{"id", "livestream_id", "tag_id"}).AddRow(2, 20, 9).AddRow(3, 20, 8).AddRow(4, 20, 9))
			mock.ExpectQuery("SELECT \\* FROM tags WHERE id IN").WithArgs(int64(9), int64(8)).WillReturnRows(sqlmock.NewRows([]string{"id", "name"}).AddRow(8, "eight").AddRow(9, "nine"))
			first := &LivestreamModel{ID: 20, UserID: 7, Title: "title", Description: "description", PlaylistUrl: "playlist", ThumbnailUrl: "thumbnail", StartAt: 100, EndAt: 200}
			got, err := fillLivestreamResponses(context.Background(), tx, []*LivestreamModel{first, {ID: 10, UserID: 7}, first})
			if err != nil {
				t.Fatal(err)
			}
			hash := sha256.Sum256(image)
			owner := User{ID: 7, Name: "owner", DisplayName: "Owner", Description: "bio", Theme: Theme{ID: 3, DarkMode: true}, IconHash: fmt.Sprintf("%x", hash)}
			wantFirst := Livestream{ID: 20, Owner: owner, Title: "title", Description: "description", PlaylistUrl: "playlist", ThumbnailUrl: "thumbnail", StartAt: 100, EndAt: 200, Tags: []Tag{{ID: 9, Name: "nine"}, {ID: 8, Name: "eight"}, {ID: 9, Name: "nine"}}}
			want := []Livestream{wantFirst, {ID: 10, Owner: owner, Tags: []Tag{}}, wantFirst}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got %#v; want %#v", got, want)
			}
			encoded, _ := json.Marshal(got)
			if !strings.Contains(string(encoded), `"tags":[]`) {
				t.Fatal(string(encoded))
			}
			mock.ExpectRollback()
			if err := tx.Rollback(); err != nil {
				t.Fatal(err)
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSearchBatchEmpty(t *testing.T) {
	got, err := fillLivestreamResponses(context.Background(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(got)
	if string(b) != "[]" {
		t.Fatal(string(b))
	}
}

func TestSearchBatchMissingOwner(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectBegin()
	tx, err := sqlx.NewDb(db, "sqlmock").Beginx()
	if err != nil {
		t.Fatal(err)
	}
	mock.ExpectQuery("SELECT \\* FROM users").WillReturnRows(sqlmock.NewRows([]string{"id"}))
	mock.ExpectQuery("SELECT \\* FROM themes").WillReturnRows(sqlmock.NewRows([]string{"id", "user_id", "dark_mode"}))
	mock.ExpectQuery("SELECT user_id, image FROM icons").WillReturnRows(sqlmock.NewRows([]string{"user_id", "image"}))
	_, err = fillLivestreamResponses(context.Background(), tx, []*LivestreamModel{{ID: 1, UserID: 7}})
	if err != sql.ErrNoRows {
		t.Fatalf("got %v", err)
	}
	mock.ExpectRollback()
	_ = tx.Rollback()
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
