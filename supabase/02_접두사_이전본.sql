-- =====================================================================
-- HD-07 Dashboard / Supabase Setup SQL
-- DB 객체 접두어: hd_07_
-- Storage 버킷: hd-07-files, hd-07-images
--
-- 중요:
-- PostgreSQL 객체명에 하이픈(-)을 직접 쓰면 매번 큰따옴표가 필요하므로,
-- 테이블/함수/트리거는 안전한 접두어 hd_07_ 을 사용합니다.
-- 화면/프로젝트명 및 Storage 버킷은 hd-07 표기를 유지합니다.
--
-- Supabase Dashboard > SQL Editor > New query 에서 전체 실행하세요.
-- 기존 public.profiles / public.posts 테이블은 건드리지 않습니다.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. HD-07 직원 프로필
-- ---------------------------------------------------------------------
create table if not exists public.hd_07_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  department text not null default '',
  role text not null default 'member'
    check (role in ('member', 'admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.hd_07_profiles
  is 'HD-07 프로젝트 대시보드 직원 프로필';

comment on column public.hd_07_profiles.role
  is 'HD-07 권한: member 또는 admin';

-- ---------------------------------------------------------------------
-- 2. HD-07 통합 게시물
-- notice   : 공지사항
-- magazine : 자유게시판(웹진형)
-- files    : 자료실
-- gallery  : 갤러리
-- ---------------------------------------------------------------------
create table if not exists public.hd_07_posts (
  id uuid primary key default gen_random_uuid(),

  category text not null
    check (category in ('notice', 'magazine', 'files', 'gallery')),

  title text not null
    check (char_length(title) between 1 and 150),

  content text not null default ''
    check (char_length(content) <= 10000),

  author_id uuid not null
    references public.hd_07_profiles(id) on delete cascade,

  status text not null default 'published'
    check (status in ('draft', 'published')),

  is_pinned boolean not null default false,

  -- 자료실
  attachment_path text,
  attachment_name text,

  -- 갤러리 대표 이미지
  cover_path text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists hd_07_posts_category_created_idx
  on public.hd_07_posts(category, created_at desc);

create index if not exists hd_07_posts_author_idx
  on public.hd_07_posts(author_id);

create index if not exists hd_07_posts_pinned_idx
  on public.hd_07_posts(category, is_pinned desc, created_at desc);

-- ---------------------------------------------------------------------
-- 3. updated_at 자동 갱신
-- ---------------------------------------------------------------------
create or replace function public.hd_07_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists hd_07_profiles_set_updated_at
  on public.hd_07_profiles;

create trigger hd_07_profiles_set_updated_at
before update on public.hd_07_profiles
for each row
execute function public.hd_07_set_updated_at();

drop trigger if exists hd_07_posts_set_updated_at
  on public.hd_07_posts;

create trigger hd_07_posts_set_updated_at
before update on public.hd_07_posts
for each row
execute function public.hd_07_set_updated_at();

-- ---------------------------------------------------------------------
-- 4. 신규 Auth 사용자 -> HD-07 프로필 자동 생성
-- ---------------------------------------------------------------------
create or replace function public.hd_07_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.hd_07_profiles (
    id,
    full_name,
    department
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'department', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- auth.users에는 여러 프로젝트용 트리거가 존재할 수 있으므로
-- HD-07 전용 이름만 삭제/재생성합니다.
drop trigger if exists hd_07_on_auth_user_created
  on auth.users;

create trigger hd_07_on_auth_user_created
after insert on auth.users
for each row
execute function public.hd_07_handle_new_user();

-- 이미 가입된 Auth 사용자도 HD-07 프로필에 보정 등록
insert into public.hd_07_profiles (
  id,
  full_name,
  department
)
select
  u.id,
  coalesce(u.raw_user_meta_data ->> 'full_name', ''),
  coalesce(u.raw_user_meta_data ->> 'department', '')
from auth.users u
left join public.hd_07_profiles p
  on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 5. 관리자 확인 함수
-- ---------------------------------------------------------------------
create or replace function public.hd_07_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.hd_07_profiles
    where id = auth.uid()
      and role = 'admin'
  );
$$;

revoke all on function public.hd_07_is_admin() from public;
grant execute on function public.hd_07_is_admin() to authenticated;

-- ---------------------------------------------------------------------
-- 6. RLS 활성화
-- ---------------------------------------------------------------------
alter table public.hd_07_profiles enable row level security;
alter table public.hd_07_posts enable row level security;

-- HD-07 프로필: 로그인 사용자끼리 이름/부서 확인 가능
drop policy if exists "hd_07_profiles_read_authenticated"
  on public.hd_07_profiles;

create policy "hd_07_profiles_read_authenticated"
on public.hd_07_profiles
for select
to authenticated
using (true);

-- 자신의 이름/부서 수정 가능
drop policy if exists "hd_07_profiles_update_own"
  on public.hd_07_profiles;

create policy "hd_07_profiles_update_own"
on public.hd_07_profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- 게시물 읽기:
-- 로그인 사용자 -> published
-- 본인 -> draft 포함
-- admin -> 전체
drop policy if exists "hd_07_posts_read_authenticated"
  on public.hd_07_posts;

create policy "hd_07_posts_read_authenticated"
on public.hd_07_posts
for select
to authenticated
using (
  status = 'published'
  or author_id = auth.uid()
  or public.hd_07_is_admin()
);

-- 게시물 등록:
-- 본인 author_id만 허용
-- 공지사항/상단고정은 admin만 허용
drop policy if exists "hd_07_posts_insert_member"
  on public.hd_07_posts;

create policy "hd_07_posts_insert_member"
on public.hd_07_posts
for insert
to authenticated
with check (
  author_id = auth.uid()
  and (
    category <> 'notice'
    or public.hd_07_is_admin()
  )
  and (
    is_pinned = false
    or public.hd_07_is_admin()
  )
);

-- 게시물 수정:
-- 작성자 또는 admin
drop policy if exists "hd_07_posts_update_own_or_admin"
  on public.hd_07_posts;

create policy "hd_07_posts_update_own_or_admin"
on public.hd_07_posts
for update
to authenticated
using (
  author_id = auth.uid()
  or public.hd_07_is_admin()
)
with check (
  (
    author_id = auth.uid()
    or public.hd_07_is_admin()
  )
  and (
    category <> 'notice'
    or public.hd_07_is_admin()
  )
  and (
    is_pinned = false
    or public.hd_07_is_admin()
  )
);

-- 게시물 삭제:
-- 작성자 또는 admin
drop policy if exists "hd_07_posts_delete_own_or_admin"
  on public.hd_07_posts;

create policy "hd_07_posts_delete_own_or_admin"
on public.hd_07_posts
for delete
to authenticated
using (
  author_id = auth.uid()
  or public.hd_07_is_admin()
);

-- ---------------------------------------------------------------------
-- 7. 권한
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;

grant select on public.hd_07_profiles to authenticated;

-- role 컬럼은 일반 사용자가 수정할 수 없도록 제외
grant update (
  full_name,
  department,
  updated_at
)
on public.hd_07_profiles
to authenticated;

grant select, insert, update, delete
on public.hd_07_posts
to authenticated;

revoke all on public.hd_07_profiles from anon;
revoke all on public.hd_07_posts from anon;

-- ---------------------------------------------------------------------
-- 8. HD-07 전용 Storage
-- ---------------------------------------------------------------------
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit
)
values
  (
    'hd-07-files',
    'hd-07-files',
    false,
    52428800
  ),
  (
    'hd-07-images',
    'hd-07-images',
    false,
    10485760
  )
on conflict (id)
do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit;

-- 로그인 사용자 파일 읽기
drop policy if exists "hd_07_storage_read_authenticated"
  on storage.objects;

create policy "hd_07_storage_read_authenticated"
on storage.objects
for select
to authenticated
using (
  bucket_id in ('hd-07-files', 'hd-07-images')
);

-- 본인 UUID 폴더에 업로드
drop policy if exists "hd_07_storage_insert_own_folder"
  on storage.objects;

create policy "hd_07_storage_insert_own_folder"
on storage.objects
for insert
to authenticated
with check (
  bucket_id in ('hd-07-files', 'hd-07-images')
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- 본인 파일 또는 admin 수정
drop policy if exists "hd_07_storage_update_own_or_admin"
  on storage.objects;

create policy "hd_07_storage_update_own_or_admin"
on storage.objects
for update
to authenticated
using (
  bucket_id in ('hd-07-files', 'hd-07-images')
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.hd_07_is_admin()
  )
)
with check (
  bucket_id in ('hd-07-files', 'hd-07-images')
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.hd_07_is_admin()
  )
);

-- 본인 파일 또는 admin 삭제
drop policy if exists "hd_07_storage_delete_own_or_admin"
  on storage.objects;

create policy "hd_07_storage_delete_own_or_admin"
on storage.objects
for delete
to authenticated
using (
  bucket_id in ('hd-07-files', 'hd-07-images')
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.hd_07_is_admin()
  )
);

-- ---------------------------------------------------------------------
-- 9. 최초 HD-07 관리자 지정
-- ---------------------------------------------------------------------
-- 1) 사이트에서 먼저 회원가입
-- 2) 아래 이메일을 실제 관리자 이메일로 수정
-- 3) 해당 UPDATE 문만 실행
--
-- update public.hd_07_profiles p
-- set role = 'admin'
-- from auth.users u
-- where p.id = u.id
--   and u.email = 'admin@company.com';

-- 관리자 확인
-- select
--   u.email,
--   p.full_name,
--   p.department,
--   p.role
-- from public.hd_07_profiles p
-- join auth.users u on u.id = p.id
-- order by p.created_at;

-- ---------------------------------------------------------------------
-- 10. 설치 확인
-- ---------------------------------------------------------------------
select
  'hd_07_profiles' as object_name,
  count(*) as row_count
from public.hd_07_profiles

union all

select
  'hd_07_posts',
  count(*)
from public.hd_07_posts;
