# テストテンプレート集

## TypeScript (Vitest)

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { UserService } from './user-service'

describe('UserService', () => {
  let service: UserService
  
  beforeEach(() => {
    service = new UserService()
  })

  describe('createUser', () => {
    // 正常系
    it('有効な入力でユーザーを作成する', async () => {
      const user = await service.createUser({ email: 'test@example.com', name: 'Test' })
      expect(user.id).toBeDefined()
      expect(user.email).toBe('test@example.com')
    })

    // 異常系
    it('無効なメールアドレスでエラーを投げる', async () => {
      await expect(
        service.createUser({ email: 'invalid', name: 'Test' })
      ).rejects.toThrow('Invalid email')
    })

    // エッジケース
    it('空の名前を許容しない', async () => {
      await expect(
        service.createUser({ email: 'test@example.com', name: '' })
      ).rejects.toThrow()
    })

    // モック使用例
    it('DBエラー時はリトライする', async () => {
      const mockDb = vi.fn()
        .mockRejectedValueOnce(new Error('DB error'))
        .mockResolvedValueOnce({ id: '1' })
      
      service.db = mockDb
      const user = await service.createUser({ email: 'test@example.com', name: 'Test' })
      expect(mockDb).toHaveBeenCalledTimes(2)
      expect(user.id).toBe('1')
    })
  })
})
```

## Python (pytest)

```python
import pytest
from unittest.mock import Mock, patch
from app.user_service import UserService, InvalidEmailError

class TestUserService:
    @pytest.fixture
    def service(self):
        return UserService()

    # 正常系
    def test_create_user_success(self, service):
        user = service.create_user(email="test@example.com", name="Test")
        assert user.id is not None
        assert user.email == "test@example.com"

    # 異常系
    def test_create_user_invalid_email(self, service):
        with pytest.raises(InvalidEmailError, match="Invalid email"):
            service.create_user(email="invalid", name="Test")

    # パラメタライズ (境界値・エッジケース)
    @pytest.mark.parametrize("name,expected_error", [
        ("", "Name required"),
        ("a", "Name too short"),
        ("a" * 256, "Name too long"),
    ])
    def test_create_user_name_validation(self, service, name, expected_error):
        with pytest.raises(ValueError, match=expected_error):
            service.create_user(email="test@example.com", name=name)

    # モック使用例
    def test_create_user_retries_on_db_error(self, service):
        with patch.object(service, 'db') as mock_db:
            mock_db.insert.side_effect = [Exception("DB error"), {"id": "1"}]
            user = service.create_user(email="test@example.com", name="Test")
            assert mock_db.insert.call_count == 2
            assert user.id == "1"
```

## Rust

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_user_success() {
        let service = UserService::new();
        let user = service.create_user("test@example.com", "Test").unwrap();
        assert!(!user.id.is_empty());
        assert_eq!(user.email, "test@example.com");
    }

    #[test]
    fn test_create_user_invalid_email() {
        let service = UserService::new();
        let result = service.create_user("invalid", "Test");
        assert!(matches!(result, Err(Error::InvalidEmail)));
    }

    #[test]
    #[should_panic(expected = "Name required")]
    fn test_create_user_empty_name() {
        let service = UserService::new();
        service.create_user("test@example.com", "").unwrap();
    }
}
```

## Go

```go
package user_test

import (
    "errors"
    "testing"
)

func TestCreateUser_Success(t *testing.T) {
    service := NewUserService()
    user, err := service.CreateUser("test@example.com", "Test")
    if err != nil {
        t.Fatalf("expected no error, got %v", err)
    }
    if user.ID == "" {
        t.Error("expected non-empty ID")
    }
}

func TestCreateUser_InvalidEmail(t *testing.T) {
    service := NewUserService()
    _, err := service.CreateUser("invalid", "Test")
    if !errors.Is(err, ErrInvalidEmail) {
        t.Errorf("expected ErrInvalidEmail, got %v", err)
    }
}

// Table-driven test (Goのイディオム)
func TestCreateUser_NameValidation(t *testing.T) {
    tests := []struct {
        name      string
        userName  string
        wantError bool
    }{
        {"empty name", "", true},
        {"too short", "a", true},
        {"too long", strings.Repeat("a", 256), true},
        {"valid", "Test User", false},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            service := NewUserService()
            _, err := service.CreateUser("test@example.com", tt.userName)
            if (err != nil) != tt.wantError {
                t.Errorf("got error=%v, want error=%v", err, tt.wantError)
            }
        })
    }
}
```

## 共通: 良いテストの自己チェック

- [ ] テスト名から仕様が読める (when X, then Y)
- [ ] 1テスト = 1アサーション (複数チェックなら describe で分割)
- [ ] テスト間の状態共有がない (beforeEach で初期化)
- [ ] 外部依存はモック化 (DB/API/ファイル/時刻)
- [ ] 境界値テストがある (0, 1, max-1, max, max+1)
- [ ] エラーケースのテストがある
- [ ] テストファイルだけ見て実装が想像できる
