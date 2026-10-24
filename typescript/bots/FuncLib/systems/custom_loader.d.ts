interface CustomizeSettings {
    Enable: boolean;
    Localization: string;
    Ban: string[];
    Radiant_Heros: string[];
    Dire_Heros: string[];
    Allow_Repeated_Heroes: boolean;
    Weak_Hero_Cap: number;
    Weak_Penalty: { type: string; base?: number; k?: number };
    Strict_Ban_Match: boolean;
    Allow_Trash_Talk: boolean;
    Trash_Talk_Level: number;
    Radiant_Names: string[];
    Dire_Names: string[];
    Show_Team_Names: boolean;
    Radiant_Team_Name: string;
    Dire_Team_Name: string;
    Push_Frequency: number;
    ThinkLess: number;
}
declare const Customize: CustomizeSettings;
export = Customize;
