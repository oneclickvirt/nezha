package controller

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/oneclickvirt/nezha/pkg/oidc/cloudflare"
	myOidc "github.com/oneclickvirt/nezha/pkg/oidc/general"

	"code.gitea.io/sdk/gitea"
	"github.com/gin-gonic/gin"
	GitHubAPI "github.com/google/go-github/v47/github"
	"github.com/oneclickvirt/nezha/model"
	"github.com/oneclickvirt/nezha/pkg/mygin"
	"github.com/oneclickvirt/nezha/pkg/utils"
	"github.com/oneclickvirt/nezha/service/singleton"
	"github.com/patrickmn/go-cache"
	"github.com/xanzy/go-gitlab"
	"golang.org/x/oauth2"
	GitHubOauth2 "golang.org/x/oauth2/github"
	GitlabOauth2 "golang.org/x/oauth2/gitlab"
	"gorm.io/gorm"
)

type oauth2controller struct {
	r            gin.IRoutes
	oidcProvider *oidc.Provider
}

var oauth2UserPersistLock sync.Mutex

func (oa *oauth2controller) serve() {
	oa.r.GET("/oauth2/login", oa.login)
	oa.r.GET("/oauth2/callback", oa.callback)
}

func (oa *oauth2controller) getCommonOauth2Config(c *gin.Context) *oauth2.Config {
	if singleton.Conf.Oauth2.Type == model.ConfigTypeGitee {
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Scopes:       []string{},
			Endpoint: oauth2.Endpoint{
				AuthURL:  "https://gitee.com/oauth/authorize",
				TokenURL: "https://gitee.com/oauth/token",
			},
			RedirectURL: oa.getRedirectURL(c),
		}
	} else if singleton.Conf.Oauth2.Type == model.ConfigTypeGitlab {
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Scopes:       []string{"read_user", "read_api"},
			Endpoint:     GitlabOauth2.Endpoint,
			RedirectURL:  oa.getRedirectURL(c),
		}
	} else if singleton.Conf.Oauth2.Type == model.ConfigTypeJihulab {
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Scopes:       []string{"read_user", "read_api"},
			Endpoint: oauth2.Endpoint{
				AuthURL:  "https://jihulab.com/oauth/authorize",
				TokenURL: "https://jihulab.com/oauth/token",
			},
			RedirectURL: oa.getRedirectURL(c),
		}
	} else if singleton.Conf.Oauth2.Type == model.ConfigTypeGitea {
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Endpoint: oauth2.Endpoint{
				AuthURL:  fmt.Sprintf("%s/login/oauth/authorize", singleton.Conf.Oauth2.Endpoint),
				TokenURL: fmt.Sprintf("%s/login/oauth/access_token", singleton.Conf.Oauth2.Endpoint),
			},
			RedirectURL: oa.getRedirectURL(c),
		}
	} else if singleton.Conf.Oauth2.Type == model.ConfigTypeCloudflare {
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Scopes:       []string{"openid", "email", "profile", "groups"},
			Endpoint: oauth2.Endpoint{
				AuthURL:  fmt.Sprintf("%s/cdn-cgi/access/sso/oidc/%s/authorization", singleton.Conf.Oauth2.Endpoint, singleton.Conf.Oauth2.ClientID),
				TokenURL: fmt.Sprintf("%s/cdn-cgi/access/sso/oidc/%s/token", singleton.Conf.Oauth2.Endpoint, singleton.Conf.Oauth2.ClientID),
			},
			RedirectURL: oa.getRedirectURL(c),
		}
	} else if singleton.Conf.Oauth2.Type == model.ConfigTypeOidc {
		var err error
		oa.oidcProvider, err = oidc.NewProvider(c.Request.Context(), singleton.Conf.Oauth2.OidcIssuer)
		if err != nil {
			mygin.ShowErrorPage(c, mygin.ErrInfo{
				Code:  http.StatusBadRequest,
				Title: fmt.Sprintf("Cannot get OIDC infomaion from issuer from %s", singleton.Conf.Oauth2.OidcIssuer),
				Msg:   err.Error(),
			}, true)
			return nil
		}
		scopes := strings.Split(singleton.Conf.Oauth2.OidcScopes, ",")
		scopes = append(scopes, oidc.ScopeOpenID)
		uniqueScopes := removeDuplicates(scopes)
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Scopes:       uniqueScopes,
			Endpoint:     oa.oidcProvider.Endpoint(),
			RedirectURL:  oa.getRedirectURL(c),
		}
	} else {
		return &oauth2.Config{
			ClientID:     singleton.Conf.Oauth2.ClientID,
			ClientSecret: singleton.Conf.Oauth2.ClientSecret,
			Scopes:       []string{},
			Endpoint:     GitHubOauth2.Endpoint,
			RedirectURL:  oa.getRedirectURL(c),
		}
	}
}

func (oa *oauth2controller) getRedirectURL(c *gin.Context) string {
	return oa.getRequestScheme(c) + c.Request.Host + "/oauth2/callback"
}

func (oa *oauth2controller) login(c *gin.Context) {
	randomString, err := utils.GenerateRandomString(32)
	if err != nil {
		mygin.ShowErrorPage(c, mygin.ErrInfo{
			Code:  http.StatusBadRequest,
			Title: "Something Wrong",
			Msg:   err.Error(),
		}, true)
		return
	}
	state, stateKey := randomString[:16], randomString[16:]
	singleton.Cache.Set(fmt.Sprintf("%s%s", model.CacheKeyOauth2State, stateKey), state, cache.DefaultExpiration)
	oauth2Config := oa.getCommonOauth2Config(c)
	if oauth2Config == nil {
		return
	}
	url := oauth2Config.AuthCodeURL(state, oauth2.AccessTypeOnline)
	oa.setCookie(c, singleton.Conf.Site.CookieName+"-sk", stateKey, 60*5)
	c.HTML(http.StatusOK, "dashboard-"+singleton.Conf.Site.DashboardTheme+"/redirect", mygin.CommonEnvironment(c, gin.H{
		"URL": url,
	}))
}

func (oa *oauth2controller) callback(c *gin.Context) {
	if oauth2Error := strings.TrimSpace(c.Query("error")); oauth2Error != "" {
		msg := oauth2Error
		if description := strings.TrimSpace(c.Query("error_description")); description != "" {
			msg = fmt.Sprintf("%s: %s", oauth2Error, description)
		}
		mygin.ShowErrorPage(c, mygin.ErrInfo{
			Code:  http.StatusBadRequest,
			Title: "登录失败",
			Msg:   fmt.Sprintf("错误信息：%s", msg),
		}, true)
		return
	}

	var err error
	// 验证登录跳转时的 State
	stateKey, err := c.Cookie(singleton.Conf.Site.CookieName + "-sk")
	oa.clearCookie(c, singleton.Conf.Site.CookieName+"-sk")
	if err == nil {
		cacheKey := fmt.Sprintf("%s%s", model.CacheKeyOauth2State, stateKey)
		state, ok := singleton.Cache.Get(cacheKey)
		singleton.Cache.Delete(cacheKey)
		if !ok || state.(string) != c.Query("state") {
			err = errors.New("非法的登录方式")
		}
	}
	oauth2Config := oa.getCommonOauth2Config(c)
	if oauth2Config == nil {
		return
	}
	ctx := context.Background()
	var otk *oauth2.Token
	if err == nil {
		code := strings.TrimSpace(c.Query("code"))
		if code == "" {
			err = errors.New("缺少授权 code")
		} else {
			otk, err = oauth2Config.Exchange(ctx, code)
		}
	}

	var user model.User

	if err == nil {
		if singleton.Conf.Oauth2.Type == model.ConfigTypeGitlab || singleton.Conf.Oauth2.Type == model.ConfigTypeJihulab {
			var gitlabApiClient *gitlab.Client
			if singleton.Conf.Oauth2.Type == model.ConfigTypeGitlab {
				gitlabApiClient, err = gitlab.NewOAuthClient(otk.AccessToken)
			} else {
				gitlabApiClient, err = gitlab.NewOAuthClient(otk.AccessToken, gitlab.WithBaseURL("https://jihulab.com/api/v4/"))
			}
			var u *gitlab.User
			if err == nil {
				u, _, err = gitlabApiClient.Users.CurrentUser()
			}
			if err == nil {
				user = model.NewUserFromGitlab(u)
			}
		} else if singleton.Conf.Oauth2.Type == model.ConfigTypeGitea {
			var giteaApiClient *gitea.Client
			giteaApiClient, err = gitea.NewClient(singleton.Conf.Oauth2.Endpoint, gitea.SetToken(otk.AccessToken))
			var u *gitea.User
			if err == nil {
				u, _, err = giteaApiClient.GetMyUserInfo()
			}
			if err == nil {
				user = model.NewUserFromGitea(u)
			}
		} else if singleton.Conf.Oauth2.Type == model.ConfigTypeCloudflare {
			client := oauth2Config.Client(context.Background(), otk)
			resp, err := client.Get(fmt.Sprintf("%s/cdn-cgi/access/sso/oidc/%s/userinfo", singleton.Conf.Oauth2.Endpoint, singleton.Conf.Oauth2.ClientID))
			if err == nil {
				defer resp.Body.Close()
				var cloudflareUserInfo *cloudflare.UserInfo
				if err := utils.Json.NewDecoder(resp.Body).Decode(&cloudflareUserInfo); err == nil {
					user = cloudflareUserInfo.MapToNezhaUser()
				}
			}
		} else if singleton.Conf.Oauth2.Type == model.ConfigTypeOidc {
			userInfo, err := oa.oidcProvider.UserInfo(c.Request.Context(), oauth2.StaticTokenSource(otk))
			if err == nil {
				loginClaim := singleton.Conf.Oauth2.OidcLoginClaim
				groupClaim := singleton.Conf.Oauth2.OidcGroupClaim
				adminGroups := strings.Split(singleton.Conf.Oauth2.AdminGroups, ",")
				autoCreate := singleton.Conf.Oauth2.OidcAutoCreate
				var oidceUserInfo *myOidc.UserInfo
				if err := userInfo.Claims(&oidceUserInfo); err == nil {
					user = oidceUserInfo.MapToNezhaUser(loginClaim, groupClaim, adminGroups, autoCreate)
				}
			}
		} else {
			var client *GitHubAPI.Client
			oc := oauth2Config.Client(ctx, otk)
			if singleton.Conf.Oauth2.Type == model.ConfigTypeGitee {
				baseURL, _ := url.Parse("https://gitee.com/api/v5/")
				uploadURL, _ := url.Parse("https://gitee.com/api/v5/uploads/")
				client = GitHubAPI.NewClient(oc)
				client.BaseURL = baseURL
				client.UploadURL = uploadURL
			} else {
				client = GitHubAPI.NewClient(oc)
			}
			var gu *GitHubAPI.User
			gu, _, err = client.Users.Get(ctx, "")
			if err == nil {
				user = model.NewUserFromGitHub(gu)
			}
		}
	}
	if err == nil {
		user.OAuth2Provider = oa.getOAuth2ProviderName()
		if user.Name == "" {
			user.Name = user.Login
		}
	}
	if err == nil && user.Login == "" {
		err = errors.New("获取用户信息失败")
	}
	var existingUser *model.User
	if err == nil {
		existingUser, err = oa.findExistingOAuth2UserTx(singleton.DB, user)
		if err == nil && existingUser != nil {
			user.ID = existingUser.ID
			user.SuperAdmin = user.SuperAdmin || existingUser.SuperAdmin
		}
	}

	if err != nil || user.Login == "" {
		mygin.ShowErrorPage(c, mygin.ErrInfo{
			Code:  http.StatusBadRequest,
			Title: "登录失败",
			Msg:   fmt.Sprintf("错误信息：%s", err),
		}, true)
		return
	}
	var isAdmin bool

	if user.SuperAdmin {
		isAdmin = true
	} else {
		for _, admin := range strings.Split(singleton.Conf.Oauth2.Admin, ",") {
			if admin != "" && strings.EqualFold(user.Login, admin) {
				isAdmin = true
				break
			}
		}
	}
	if !isAdmin {
		mygin.ShowErrorPage(c, mygin.ErrInfo{
			Code:  http.StatusBadRequest,
			Title: "登录失败",
			Msg:   fmt.Sprintf("错误信息：%s", "该用户不是本站点管理员，无法登录"),
		}, true)
		return
	}
	user.Token, err = utils.GenerateRandomString(32)
	if err != nil {
		mygin.ShowErrorPage(c, mygin.ErrInfo{
			Code:  http.StatusBadRequest,
			Title: "Something wrong",
			Msg:   err.Error(),
		}, true)
		return
	}
	user.TokenExpired = time.Now().AddDate(0, 2, 0)
	savedUser, err := oa.persistOAuth2User(&user)
	if err != nil {
		mygin.ShowErrorPage(c, mygin.ErrInfo{
			Code:  http.StatusBadRequest,
			Title: "登录失败",
			Msg:   fmt.Sprintf("错误信息：%s", err),
		}, true)
		return
	}
	user = *savedUser
	oa.setCookie(c, singleton.Conf.Site.CookieName, user.Token, 60*60*24)
	c.HTML(http.StatusOK, "dashboard-"+singleton.Conf.Site.DashboardTheme+"/redirect", mygin.CommonEnvironment(c, gin.H{
		"URL": "/",
	}))
}

func (oa *oauth2controller) getRequestScheme(c *gin.Context) string {
	if c.Request.TLS != nil {
		return "https://"
	}
	referer := c.Request.Referer()
	if forwardedProto := c.Request.Header.Get("X-Forwarded-Proto"); forwardedProto == "https" || strings.HasPrefix(referer, "https://") {
		return "https://"
	}
	return "http://"
}

func (oa *oauth2controller) shouldSecureCookie(c *gin.Context) bool {
	return oa.getRequestScheme(c) == "https://"
}

func (oa *oauth2controller) setCookie(c *gin.Context, name string, value string, maxAge int) {
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie(name, value, maxAge, "/", "", oa.shouldSecureCookie(c), true)
}

func (oa *oauth2controller) clearCookie(c *gin.Context, name string) {
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie(name, "", -1, "/", "", oa.shouldSecureCookie(c), true)
}

func (oa *oauth2controller) getOAuth2ProviderName() string {
	switch singleton.Conf.Oauth2.Type {
	case model.ConfigTypeGitee:
		return "gitee"
	case model.ConfigTypeGitlab:
		return "gitlab"
	case model.ConfigTypeJihulab:
		return "jihulab"
	case model.ConfigTypeGitea:
		return "gitea"
	case model.ConfigTypeCloudflare:
		return "cloudflare"
	case model.ConfigTypeOidc:
		return "oidc"
	default:
		return "github"
	}
}

func (oa *oauth2controller) persistOAuth2User(user *model.User) (*model.User, error) {
	oauth2UserPersistLock.Lock()
	defer oauth2UserPersistLock.Unlock()

	var savedUser model.User
	err := singleton.DB.Transaction(func(tx *gorm.DB) error {
		existingUser, err := oa.findExistingOAuth2UserTx(tx, *user)
		if err != nil {
			return err
		}
		if existingUser == nil {
			if err := tx.Create(user).Error; err != nil {
				return err
			}
			savedUser = *user
			return nil
		}

		user.ID = existingUser.ID
		user.SuperAdmin = user.SuperAdmin || existingUser.SuperAdmin
		if err := oa.saveOAuth2UserTx(tx, existingUser, user); err != nil {
			return err
		}
		savedUser = *existingUser
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &savedUser, nil
}

func (oa *oauth2controller) findExistingOAuth2UserTx(db *gorm.DB, user model.User) (*model.User, error) {
	var existing model.User
	if user.OAuth2Provider != "" && user.OAuth2UID != "" {
		err := db.Where("oauth2_provider = ? AND oauth2_uid = ?", user.OAuth2Provider, user.OAuth2UID).First(&existing).Error
		switch {
		case err == nil:
			return &existing, nil
		case !errors.Is(err, gorm.ErrRecordNotFound):
			return nil, err
		}
	}

	err := db.Where("LOWER(login) = LOWER(?)", user.Login).First(&existing).Error
	switch {
	case err == nil:
		if existing.OAuth2Provider != "" && existing.OAuth2Provider != user.OAuth2Provider {
			return nil, fmt.Errorf("登录名 %s 已绑定到其他 OAuth2 提供方", user.Login)
		}
		if existing.OAuth2UID != "" && user.OAuth2UID != "" && existing.OAuth2UID != user.OAuth2UID {
			return nil, fmt.Errorf("登录名 %s 已绑定到其他 OAuth2 账号", user.Login)
		}
		return &existing, nil
	case errors.Is(err, gorm.ErrRecordNotFound):
		return nil, nil
	default:
		return nil, err
	}
}

func (oa *oauth2controller) saveOAuth2UserTx(db *gorm.DB, existingUser *model.User, user *model.User) error {
	if existingUser == nil {
		return db.Create(user).Error
	}

	existingUser.Login = user.Login
	if user.AvatarURL != "" {
		existingUser.AvatarURL = user.AvatarURL
	}
	if user.Name != "" {
		existingUser.Name = user.Name
	}
	if user.Blog != "" {
		existingUser.Blog = user.Blog
	}
	if user.Email != "" {
		existingUser.Email = user.Email
	}
	existingUser.Hireable = user.Hireable
	if user.Bio != "" {
		existingUser.Bio = user.Bio
	}
	existingUser.OAuth2Provider = user.OAuth2Provider
	if user.OAuth2UID != "" {
		existingUser.OAuth2UID = user.OAuth2UID
	}
	existingUser.SuperAdmin = existingUser.SuperAdmin || user.SuperAdmin
	existingUser.Token = user.Token
	existingUser.TokenExpired = user.TokenExpired

	return db.Save(existingUser).Error
}

func removeDuplicates(elements []string) []string {
	encountered := map[string]bool{}
	result := []string{}

	for _, v := range elements {
		if !encountered[v] {
			encountered[v] = true
			result = append(result, v)
		}
	}
	return result
}
