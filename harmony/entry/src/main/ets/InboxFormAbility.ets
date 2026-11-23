import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { inboxFormData, registerInboxForm } from './InboxWidget';

export default class InboxFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const id = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    if (typeof id === 'string') registerInboxForm(this.context, id, true);
    return inboxFormData(this.context);
  }

  onUpdateForm(id: string): void {
    registerInboxForm(this.context, id, true);
    void formProvider.updateForm(id, inboxFormData(this.context)).catch((): void => {});
  }

  onRemoveForm(id: string): void {
    registerInboxForm(this.context, id, false);
  }
}
