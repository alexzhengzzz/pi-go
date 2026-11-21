import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';

export interface HuaweiProfile {
  openId: string;
  name: string;
  avatar: string;
}

export async function authorizeHuaweiProfile(context: common.Context): Promise<HuaweiProfile> {
  const request = new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
  request.scopes = ['openid', 'profile'];
  request.forceAuthorization = true;
  const state = util.generateRandomUUID();
  request.state = state;
  const response = await new authentication.AuthenticationController(context).executeRequest(request) as
    authentication.AuthorizationWithHuaweiIDResponse;
  const data = response.data;
  if (response.state !== state || !data?.openID) throw new Error('invalid_huawei_profile');
  return {
    openId: data.openID,
    name: data.nickName || '华为账号',
    avatar: data.avatarUri?.startsWith('https://') ? data.avatarUri : ''
  };
}

export async function isHuaweiProfileCurrent(profile: HuaweiProfile): Promise<boolean> {
  const result = await new authentication.HuaweiIDProvider().getHuaweiIDState({
    idType: authentication.IdType.OPEN_ID,
    idValue: profile.openId
  });
  return result.state === authentication.State.AUTHORIZED;
}
