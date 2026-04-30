package general

import (
	"errors"

	"github.com/oneclickvirt/nezha/model"
	"github.com/oneclickvirt/nezha/service/singleton"
	"gorm.io/gorm"
)

type UserInfo struct {
	Sub      string   `json:"sub"`
	Username string   `json:"preferred_username"`
	Email    string   `json:"email"`
	Name     string   `json:"name"`
	Groups   []string `json:"groups,omitempty"`
	Roles    []string `json:"roles,omitempty"`
}

func (u UserInfo) MapToNezhaUser(loginClaim string, groupClaim string, adminGroups []string, autoCreate bool) model.User {
	var login string
	var groups []string
	var isAdmin bool
	if loginClaim == "email" {
		login = u.Email
	} else if loginClaim == "preferred_username" {
		login = u.Username
	} else {
		login = u.Sub
	}
	if groupClaim == "roles" {
		groups = u.Roles
	} else {
		groups = u.Groups
	}
	// Check if user is admin
	adminGroupSet := make(map[string]struct{}, len(adminGroups))
	for _, adminGroup := range adminGroups {
		adminGroupSet[adminGroup] = struct{}{}
	}
	for _, group := range groups {
		if _, found := adminGroupSet[group]; found {
			isAdmin = true
			break
		}
	}
	user := model.User{
		Login:      login,
		Email:      u.Email,
		Name:       u.Name,
		SuperAdmin: isAdmin,
		OAuth2UID:  u.Sub,
	}
	if user.Name == "" {
		user.Name = user.Login
	}
	if autoCreate || user.Login == "" {
		return user
	}

	var existing model.User
	if err := singleton.DB.Where("LOWER(login) = LOWER(?)", login).First(&existing).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return model.User{}
		}
		return model.User{}
	}
	user.ID = existing.ID
	user.SuperAdmin = user.SuperAdmin || existing.SuperAdmin
	return user
}
