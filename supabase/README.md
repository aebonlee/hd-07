# hd-07 Supabase 설정

이 폴더의 SQL 은 **대표 PC 에만 있던 것**을 저장소로 옮긴 것입니다.
저장소에 없으면 사이트만 남고 표를 어떻게 만들었는지는 사라집니다.

## 지금 어떤 상태인가 (2026-08-25 실측)

| | 표 | 버킷 | 화면이 쓰는가 |
|---|---|---|---|
| **현재 운영본** | `posts` · `profiles` | `project-images` · `project-files` | ✅ 예 |
| **접두사 이전본** | `hd_07_posts` · `hd_07_profiles` | `hd-07-images` · `hd-07-files` | ❌ 아니오 |

**두 벌 다 이미 만들어져 있습니다.** 이전본 표와 버킷은 서버에 존재하고,
화면(`index.html`)만 아직 옛 이름을 부르고 있습니다.

## 왜 접두사를 붙이려 했나

이 프로젝트는 **여러 사이트가 함께 쓰는 Supabase 프로젝트**에 올라가 있습니다.
`posts` · `profiles` 같은 이름은 다른 사이트도 쓰기 쉬운 흔한 이름이라,
같은 표를 두 사이트가 나눠 쓰게 될 수 있습니다.
그러면 한쪽에서 지운 행이 다른 쪽에서도 사라집니다.

## 전환하려면

1. **먼저 `posts` · `profiles` 에 남은 자료가 있는지 확인하세요.**
   비로그인으로는 0건으로 보이지만, 그것은 RLS 가 가린 것일 수도 있습니다.
   대시보드 Table Editor 에서 직접 보세요. 자료가 있으면 옮긴 뒤에 바꿔야 합니다.

   ```sql
   select count(*) from public.posts;
   select count(*) from public.profiles;
   ```

2. 자료를 옮깁니다(있을 때만).

   ```sql
   insert into public.hd_07_profiles select * from public.profiles
     on conflict do nothing;
   insert into public.hd_07_posts    select * from public.posts
     on conflict do nothing;
   ```

3. `index.html` 에서 이름을 바꿉니다.

   ```
   .from('posts')            → .from('hd_07_posts')
   .from('profiles')         → .from('hd_07_profiles')
   storage.from('project-images') → storage.from('hd-07-images')
   storage.from('project-files')  → storage.from('hd-07-files')
   ```

4. **로그인 전 화면을 확인하세요.** 이전본은 `anon` 에 권한을 주지 않았습니다
   (`authenticated` 에만 부여). 그래서 로그인하기 전에 목록을 읽으면
   `42501 permission denied` 가 납니다. 옛 표는 `anon` 도 읽을 수 있어
   빈 목록이 보였는데, 바꾸면 오류로 바뀝니다.
   로그인 화면을 먼저 띄우거나, 필요하면 아래를 더하면 됩니다.

   ```sql
   grant select on public.hd_07_posts to anon;
   ```

## 파일

- `01_현재_운영본.sql` — 지금 화면이 쓰는 `posts` · `profiles`
  (대표 PC 의 `h.sql` 과 `supabase_setup.sql` 이 같은 내용이라 하나만 남겼습니다)
- `02_접두사_이전본.sql` — `hd_07_` 접두사 판. 이미 실행되어 표가 존재합니다.

> **아직 전환하지 않은 이유**: 옛 표에 수업 중 올린 글이 남아 있을 수 있는데,
> 밖에서는 RLS 때문에 있는지 없는지 구분할 수 없습니다.
> 확인하지 않고 바꾸면 화면이 비어 보입니다.
