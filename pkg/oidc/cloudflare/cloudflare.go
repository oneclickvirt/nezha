package cloudflare

import (
	"github.com/oneclickvirt/nezha/model"
)

type UserInfo struct {
	Sub    string   `json:"sub"`
	Email  string   `json:"email"`
	Name   string   `json:"name"`
	Groups []string `json:"groups"`
}

func (u UserInfo) MapToNezhaUser() model.User {
	user := model.User{
		Login:     u.Sub,
		Email:     u.Email,
		Name:      u.Name,
		OAuth2UID: u.Sub,
	}
	if user.Login == "" {
		user.Login = user.Email
	}
	if user.Name == "" {
		user.Name = user.Login
	}
	return user
}
