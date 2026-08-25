-- ================================================================
-- PROJECT BLUE / Supabase Setup SQL
-- 공지사항 + 웹진형 자유게시판 + 자료실 + 갤러리 + 간단 회원 프로필
-- Supabase Dashboard > SQL Editor > New query 에서 전체 실행
-- ================================================================

-- 0) Extensions
create extension if not exists "pgcrypto";

-- 1) Profiles
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  department text not null default '',
  role text not null default 'member' check (role in ('member','admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is '프로젝트 사이트 직원 프로필';
comment on column public.profiles.role is 'member 또는 admin';

-- 2) Posts
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('notice','magazine','files','gallery')),
  title text not null check (char_length(title) between 1 and 150),
  content text not null default '' check (char_length(content) <= 10000),
  author_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'published' check (status in ('draft','published')),
  is_pinned boolean not null default false,

  -- 자료실용 1개 첨부파일 메타데이터
  attachment_path text,
  attachment_name text,

  -- 갤러리용 대표 이미지 경로
  cover_path text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists posts_category_created_idx
  on public.posts(category, created_at desc);

create index if not exists posts_author_idx
  on public.posts(author_id);

create index if not exists posts_pinned_idx
  on public.posts(category, is_pinned desc, created_at desc);

-- 3) 공통 updated_at trigger
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute procedure public.set_updated_at();

drop trigger if exists posts_set_updated_at on public.posts;
create trigger posts_set_updated_at
before update on public.posts
for each row execute procedure public.set_updated_at();

-- 4) auth.users 가입 시 profiles 자동 생성
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, department)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'department', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- 기존 Auth 사용자 중 profiles가 없는 사용자가 있다면 보정
insert into public.profiles (id, full_name, department)
select
  u.id,
  coalesce(u.raw_user_meta_data ->> 'full_name', ''),
  coalesce(u.raw_user_meta_data ->> 'department', '')
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- 5) 관리자 확인 helper
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- 6) RLS 활성화
alter table public.profiles enable row level security;
alter table public.posts enable row level security;

-- Profiles policies
drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated"
on public.profiles
for select
to authenticated
using (true);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- role 컬럼은 authenticated에게 UPDATE 권한을 부여하지 않습니다.
-- 따라서 사용자는 RLS를 통과하더라도 자신의 role을 admin으로 변경할 수 없습니다.

-- Posts SELECT: 로그인한 직원만 published 게시물 열람
drop policy if exists "posts_read_authenticated" on public.posts;
create policy "posts_read_authenticated"
on public.posts
for select
to authenticated
using (
  status = 'published'
  or author_id = auth.uid()
  or public.is_admin()
);

-- Posts INSERT:
-- 1) 일반 게시판은 본인이 작성 가능
-- 2) 공지사항은 admin만 작성 가능
drop policy if exists "posts_insert_member" on public.posts;
create policy "posts_insert_member"
on public.posts
for insert
to authenticated
with check (
  author_id = auth.uid()
  and (
    category <> 'notice'
    or public.is_admin()
  )
  and (
    is_pinned = false
    or public.is_admin()
  )
);

-- Posts UPDATE: 작성자 본인 또는 admin
-- 공지사항으로 category를 변경하거나 pinned=true로 바꾸는 것은 admin만 허용
drop policy if exists "posts_update_own_or_admin" on public.posts;
create policy "posts_update_own_or_admin"
on public.posts
for update
to authenticated
using (
  author_id = auth.uid()
  or public.is_admin()
)
with check (
  (
    author_id = auth.uid()
    or public.is_admin()
  )
  and (
    category <> 'notice'
    or public.is_admin()
  )
  and (
    is_pinned = false
    or public.is_admin()
  )
);

-- Posts DELETE: 작성자 본인 또는 admin
drop policy if exists "posts_delete_own_or_admin" on public.posts;
create policy "posts_delete_own_or_admin"
on public.posts
for delete
to authenticated
using (
  author_id = auth.uid()
  or public.is_admin()
);

-- 7) 최소 권한 grant
grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, department, updated_at) on public.profiles to authenticated;

grant select, insert, update, delete on public.posts to authenticated;

-- 익명 사용자(비로그인)는 프로젝트 콘텐츠 접근 금지
revoke all on public.profiles from anon;
revoke all on public.posts from anon;

-- 8) Storage buckets
-- private bucket: 로그인한 직원만 SELECT 가능
insert into storage.buckets (id, name, public, file_size_limit)
values
  ('project-files', 'project-files', false, 52428800),
  ('project-images', 'project-images', false, 10485760)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit;

-- Storage policies
-- SELECT: 로그인 사용자라면 프로젝트 버킷 파일 읽기 가능
drop policy if exists "project_storage_read_authenticated" on storage.objects;
create policy "project_storage_read_authenticated"
on storage.objects
for select
to authenticated
using (
  bucket_id in ('project-files','project-images')
);

-- INSERT: 본인 UUID 폴더에만 업로드
drop policy if exists "project_storage_insert_own_folder" on storage.objects;
create policy "project_storage_insert_own_folder"
on storage.objects
for insert
to authenticated
with check (
  bucket_id in ('project-files','project-images')
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- UPDATE: 본인 폴더 또는 admin
drop policy if exists "project_storage_update_own_or_admin" on storage.objects;
create policy "project_storage_update_own_or_admin"
on storage.objects
for update
to authenticated
using (
  bucket_id in ('project-files','project-images')
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_admin()
  )
)
with check (
  bucket_id in ('project-files','project-images')
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_admin()
  )
);

-- DELETE: 본인 폴더 또는 admin
drop policy if exists "project_storage_delete_own_or_admin" on storage.objects;
create policy "project_storage_delete_own_or_admin"
on storage.objects
for delete
to authenticated
using (
  bucket_id in ('project-files','project-images')
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_admin()
  )
);

-- 9) 최초 관리자 지정 방법
-- 회원가입을 먼저 완료한 뒤 아래 이메일을 실제 관리자 이메일로 바꾸고 실행하세요.
--
-- update public.profiles p
-- set role = 'admin'
-- from auth.users u
-- where p.id = u.id
--   and u.email = 'admin@company.com';
--
-- 확인:
-- select u.email, p.full_name, p.department, p.role
-- from public.profiles p
-- join auth.users u on u.id = p.id
-- order by p.created_at;

-- 10) 선택 사항: 이메일 인증
-- Dashboard > Authentication > Sign In / Providers > Email
-- 운영 정책에 맞게 Confirm email 옵션을 켜면 회원가입 후 이메일 확인 절차가 적용됩니다.

-- ================================================================
-- 설치 확인용
-- ================================================================
select 'profiles' as object_name, count(*) as row_count from public.profiles
union all
select 'posts', count(*) from public.posts;
